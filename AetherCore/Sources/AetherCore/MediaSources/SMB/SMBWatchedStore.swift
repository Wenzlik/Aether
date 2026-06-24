import Foundation
import os

/// On-device record of which SMB files the user marked watched, keyed by the
/// file's stream URL (an SMB `MediaID`'s `rawValue`). SMB has no server to hold
/// play state, so watched is tracked locally — mirroring `SMBMetadataStore`'s
/// Application Support JSON persistence. Survives relaunch; safe to evict.
public actor SMBWatchedStore {
    public static let shared = SMBWatchedStore()
    private static let log = Logger(subsystem: "cz.zmrhal.aether", category: "smb-watched")

    private var keys: Set<String> = []
    private let fileURL: URL?
    private var loaded = false

    public init(directory: URL? = nil) {
        let dir = directory ?? (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
        self.fileURL = dir?.appendingPathComponent("SMBWatched.json")
    }

    private func hydrate() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return }
        keys = Set(decoded)
    }

    /// All watched stream-URL keys (read once per library walk to stamp items).
    public func watchedKeys() -> Set<String> {
        hydrate()
        return keys
    }

    public func isWatched(_ key: String) -> Bool {
        hydrate()
        return keys.contains(key)
    }

    /// Mark one file watched / unwatched and persist.
    public func setWatched(_ key: String, _ value: Bool) {
        hydrate()
        let changed = value ? keys.insert(key).inserted : (keys.remove(key) != nil)
        if changed { persist() }
    }

    private func persist() {
        guard let fileURL, let data = try? JSONEncoder().encode(Array(keys)) else { return }
        do { try data.write(to: fileURL, options: .atomic) }
        catch { Self.log.error("SMB watched persist failed: \(error.localizedDescription, privacy: .public)") }
    }
}
