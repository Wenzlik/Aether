import Foundation
import ImageIO
import CryptoKit
import os
#if canImport(UIKit)
import UIKit
public typealias AetherPlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
public typealias AetherPlatformImage = NSImage
#endif

extension AetherPlatformImage {
    /// Cross-platform construction from a decoded `CGImage` (the app runs UIKit;
    /// the AppKit branch only exists so AetherCore compiles on macOS for CI).
    static func aetherImage(cgImage: CGImage) -> AetherPlatformImage {
        #if canImport(UIKit)
        UIImage(cgImage: cgImage)
        #else
        NSImage(cgImage: cgImage, size: .zero)
        #endif
    }

    static func aetherImage(data: Data) -> AetherPlatformImage? {
        #if canImport(UIKit)
        UIImage(data: data)
        #else
        NSImage(data: data)
        #endif
    }

    /// Approximate decoded-pixel byte cost for the NSCache cost limit.
    var aetherPixelCost: Int {
        #if canImport(UIKit)
        Int(size.width * scale) * Int(size.height * scale) * 4
        #else
        Int(size.width) * Int(size.height) * 4
        #endif
    }
}

/// Two-tier (memory + disk) artwork cache with in-flight de-duplication and
/// downsampling. Replaces the old `CachedAsyncImage` = raw `AsyncImage` (which
/// had no persistent cache, decoded full-size, and re-fetched on every render /
/// relaunch).
///
/// Design:
/// - **Memory:** `NSCache<NSString, UIImage>` (thread-safe, auto-evicts under
///   pressure), cost = decoded pixel bytes.
/// - **Disk:** original bytes under Caches/, filename = SHA-256 of the *stable*
///   cache key, so relaunch reads from disk, never the network.
/// - **De-dup:** concurrent requests for the same key share **one** download —
///   the same unified title shown in several rails fetches its poster once.
/// - **Downsample:** decode via ImageIO `CGImageSourceCreateThumbnailAtIndex`
///   to a max pixel size, slashing memory + decode cost on scroll.
///
/// **Stable cache key:** the URL with auth query items stripped
/// (`X-Plex-Token`, `api_key`) — so a rotated token doesn't bust the cache, and
/// the key is content-addressed by path + image tag. Never keyed on the volatile
/// `UnifiedMediaItem.id`.
public final class AetherImageCache: @unchecked Sendable {
    public static let shared = AetherImageCache()

    /// Default longest-edge downsample target. Generous enough for full-width
    /// heroes on iPad / tvOS, while still cutting multi-thousand-pixel server
    /// originals down hard.
    public static let defaultMaxPixel: CGFloat = 1200

    private let memory = NSCache<NSString, AetherPlatformImage>()
    private let diskDirectory: URL
    private let fileManager = FileManager.default
    private let lock = NSLock()
    private var inFlight: [String: Task<SendableImage?, Never>] = [:]
    private let log = Logger(subsystem: "cz.zmrhal.aether", category: "images")

    /// Wraps a `UIImage` so it can cross `Task`/actor boundaries under Swift 6
    /// strict concurrency (UIImage isn't `Sendable`; we treat it as immutable).
    private struct SendableImage: @unchecked Sendable { let image: AetherPlatformImage }

    private init() {
        memory.totalCostLimit = 80 * 1024 * 1024   // ~80 MB of decoded pixels
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        diskDirectory = base.appendingPathComponent("AetherImageCache", isDirectory: true)
        try? fileManager.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    /// Return the downsampled image for `url`: memory → disk → network, with
    /// in-flight de-duplication. `nil` on failure (the view shows its skeleton).
    public func image(for url: URL, maxPixel: CGFloat = AetherImageCache.defaultMaxPixel) async -> AetherPlatformImage? {
        let key = Self.cacheKey(for: url)

        if let hit = memory.object(forKey: key as NSString) {
            log.debug("hit(memory) key=\(Self.redact(key), privacy: .public)")
            return hit
        }

        // Share an in-flight load if one exists for this key (de-dup). `withLock`
        // (sync) keeps this Swift-6-safe — `NSLock.lock()` is barred in async
        // contexts. The check-and-register is atomic so two callers can't both
        // start a download for the same key.
        var isOwner = false
        let task: Task<SendableImage?, Never> = lock.withLock {
            if let existing = inFlight[key] { return existing }
            let created = Task.detached(priority: .utility) { [weak self] in
                await self?.load(url: url, key: key, maxPixel: maxPixel)
            }
            inFlight[key] = created
            isOwner = true
            return created
        }
        if !isOwner { log.debug("dedup key=\(Self.redact(key), privacy: .public)") }

        let result = await task.value
        if isOwner { lock.withLock { _ = inFlight.removeValue(forKey: key) } }
        return result?.image
    }

    /// Warm the cache for off-screen items (rails / grid) ahead of scroll.
    /// Skips anything already in memory; rides the same de-dup path so it never
    /// duplicates an in-flight request.
    public func prefetch(_ urls: [URL?], maxPixel: CGFloat = AetherImageCache.defaultMaxPixel) {
        for case let url? in urls where memory.object(forKey: Self.cacheKey(for: url) as NSString) == nil {
            Task.detached(priority: .background) { [weak self] in
                _ = await self?.image(for: url, maxPixel: maxPixel)
            }
        }
    }

    // MARK: - Load pipeline

    private func load(url: URL, key: String, maxPixel: CGFloat) async -> SendableImage? {
        let started = Date()

        // 1. Disk.
        if let data = readDisk(key) {
            if let image = Self.downsample(data, maxPixel: maxPixel) {
                store(image, key: key)
                log.debug("hit(disk) key=\(Self.redact(key), privacy: .public) px=\(Int(image.size.width))x\(Int(image.size.height))")
                return SendableImage(image: image)
            }
        }

        // 2. Network.
        guard let data = try? await URLSession.shared.data(from: url).0, !data.isEmpty else {
            log.debug("miss(network-fail) key=\(Self.redact(key), privacy: .public)")
            return nil
        }
        writeDisk(key, data)
        guard let image = Self.downsample(data, maxPixel: maxPixel) else { return nil }
        store(image, key: key)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        log.debug("miss→fetched key=\(Self.redact(key), privacy: .public) \(ms)ms px=\(Int(image.size.width))x\(Int(image.size.height)) bytes=\(data.count)")
        return SendableImage(image: image)
    }

    private func store(_ image: AetherPlatformImage, key: String) {
        memory.setObject(image, forKey: key as NSString, cost: image.aetherPixelCost)
    }

    // MARK: - Disk

    private func diskURL(_ key: String) -> URL {
        diskDirectory.appendingPathComponent(Self.sha256(key))
    }

    private func readDisk(_ key: String) -> Data? {
        try? Data(contentsOf: diskURL(key))
    }

    private func writeDisk(_ key: String, _ data: Data) {
        try? data.write(to: diskURL(key), options: .atomic)
    }

    // MARK: - Helpers

    /// Decode at a downsampled size via ImageIO — far cheaper in memory + CPU
    /// than `UIImage(data:)` of a full-resolution server original.
    private static func downsample(_ data: Data, maxPixel: CGFloat) -> AetherPlatformImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return AetherPlatformImage.aetherImage(data: data)
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return AetherPlatformImage.aetherImage(data: data)
        }
        return AetherPlatformImage.aetherImage(cgImage: cg)
    }

    /// Stable key: drop auth query items so a rotated token doesn't bust the
    /// cache, leaving path + image tag (content-addressed).
    static func cacheKey(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        let stripped: Set<String> = ["x-plex-token", "api_key", "x-plex-client-identifier"]
        components.queryItems = components.queryItems?.filter { !stripped.contains($0.name.lowercased()) }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.url?.absoluteString ?? url.absoluteString
    }

    private static func sha256(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Redact the host so logs never carry a server address / token, just the
    /// path that identifies the artwork.
    private static func redact(_ key: String) -> String {
        guard let url = URL(string: key) else { return key }
        return url.path + (url.query.map { "?\($0)" } ?? "")
    }
}
