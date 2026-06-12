import Foundation
import os

/// Persistent cache of TMDb matches for SMB titles, keyed by a stable
/// `kind|title|year` signature (#213). It makes SMB poster matching **bounded
/// and battery-friendly**:
///
/// - a title is matched against TMDb **once, ever** — the result (hit *or* miss)
///   is persisted, so relaunching or re-browsing never re-hits the network for
///   a title we've already seen;
/// - misses are remembered too, so an unmatchable filename isn't retried on
///   every browse (until the user edits its title/year or forces a refresh,
///   which clears the misses);
/// - there's no background daemon — enrichment runs only while the user is
///   browsing SMB, against the still-unseen titles.
///
/// Stored as one small JSON file in Application Support. Global (keyed by the
/// title signature, which is connection-independent), so the same film matched
/// once is instant on every share/device.
public actor SMBMetadataStore {
    public static let shared = SMBMetadataStore()

    /// What we know about a title key.
    public enum Lookup: Sendable {
        case unknown                 // never tried → match it
        case miss                    // tried, no TMDb result → don't retry
        case hit(TMDbMetadata)       // matched → reuse
    }

    /// A user correction of an SMB item's title/year (#213), so a mis-parsed
    /// filename can be fixed to match TMDb. Keyed per item (its stream URL).
    public struct Override: Codable, Sendable, Hashable {
        public var title: String?
        public var year: Int?
        public init(title: String? = nil, year: Int? = nil) {
            self.title = title
            self.year = year
        }
        public var isEmpty: Bool { (title?.isEmpty ?? true) && year == nil }
    }

    private struct Persisted: Codable {
        var matches: [String: TMDbMetadata] = [:]
        var tried: [String] = []
        var overrides: [String: Override] = [:]
    }

    private var matches: [String: TMDbMetadata] = [:]
    private var tried: Set<String> = []
    private var overrides: [String: Override] = [:]
    private var loaded = false
    private let fileURL: URL?
    private static let log = Logger(subsystem: "cz.zmrhal.aether", category: "smb.metadata")

    /// `Application Support/Aether/SMBMetadata.json`. A `nil` URL (sandbox
    /// failure) degrades to an in-memory cache for the session.
    public init(directory: URL? = nil) {
        if let directory {
            self.fileURL = directory.appendingPathComponent("SMBMetadata.json")
        } else if let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) {
            let dir = support.appendingPathComponent("Aether", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("SMBMetadata.json")
        } else {
            self.fileURL = nil
        }
    }

    /// Stable, connection-independent key for a title. Edits to title/year
    /// produce a new key (→ a fresh match), which is exactly what we want.
    public static func key(title: String, year: Int?, isEpisode: Bool) -> String {
        "\(isEpisode ? "tv" : "movie")|\(title.lowercased())|\(year.map(String.init) ?? "")"
    }

    public func lookup(_ key: String) -> Lookup {
        loadIfNeeded()
        if let metadata = matches[key] { return .hit(metadata) }
        return tried.contains(key) ? .miss : .unknown
    }

    /// Record a match attempt (a `nil` metadata = a miss) and persist.
    public func record(_ metadata: TMDbMetadata?, for key: String) {
        loadIfNeeded()
        tried.insert(key)
        if let metadata { matches[key] = metadata }
        persist()
    }

    /// Forget the misses so the next browse retries unmatched titles (a refresh).
    /// Keeps the hits — those don't need re-fetching.
    public func clearMisses() {
        loadIfNeeded()
        tried = Set(matches.keys)
        persist()
    }

    /// Wipe everything (used when the user disconnects SMB / a full reset).
    public func clearAll() {
        matches = [:]
        tried = []
        overrides = [:]
        loaded = true
        persist()
    }

    // MARK: - User overrides (#213 title/year editing)

    /// The user's title/year correction for an item (its stream URL), if any.
    public func override(forItem itemKey: String) -> Override? {
        loadIfNeeded()
        return overrides[itemKey]
    }

    /// All overrides, for applying during a walk (keyed by item stream URL).
    public func allOverrides() -> [String: Override] {
        loadIfNeeded()
        return overrides
    }

    /// Save (or clear, when empty) the user's correction for an item and persist.
    public func setOverride(_ override: Override?, forItem itemKey: String) {
        loadIfNeeded()
        if let override, !override.isEmpty {
            overrides[itemKey] = override
        } else {
            overrides[itemKey] = nil
        }
        persist()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        matches = decoded.matches
        tried = Set(decoded.tried)
        overrides = decoded.overrides
    }

    private func persist() {
        guard let fileURL else { return }
        let snapshot = Persisted(matches: matches, tried: Array(tried), overrides: overrides)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        do { try data.write(to: fileURL, options: .atomic) }
        catch { Self.log.error("SMB metadata persist failed: \(error.localizedDescription, privacy: .public)") }
    }
}
