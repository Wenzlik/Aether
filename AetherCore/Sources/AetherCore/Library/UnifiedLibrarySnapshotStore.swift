import Foundation

/// Cross-launch persistence for the deduplicated unified catalog, so a cold
/// start can paint the **last known library** immediately instead of flashing a
/// loading state while every server is re-queried (issue #197). Complements the
/// in-memory `UnifiedLibraryCache` (45 s in-session reuse) with a disk snapshot
/// that survives relaunch and carries a timestamp for staleness.
///
/// Stored on-device only, in the app's Caches directory — the same trust
/// boundary the keychain + the URL-keyed image cache already use (the snapshot
/// contains tokenised artwork URLs). It is **not** transmitted anywhere and is
/// safe to evict; a miss just falls back to a live fetch.
///
/// Keyed identically to `UnifiedLibraryCache` (`kind + sorted connected-source
/// ids`), so a different account / source set is a natural miss rather than
/// serving another login's catalog.
public actor UnifiedLibrarySnapshotStore {
    /// Process-wide instance backed by the Caches directory. Call sites build
    /// their own `UnifiedLibrary`, so the snapshot — like the in-memory cache —
    /// is shared through this singleton.
    public static let shared = UnifiedLibrarySnapshotStore(directory: defaultDirectory())

    /// One persisted catalog: the merged items plus when they were captured.
    public struct Snapshot: Sendable {
        public let items: [UnifiedMediaItem]
        public let savedAt: Date
        /// Seconds since capture, against the supplied clock-now (caller passes
        /// `Date()` in production; tests pass a fixed instant).
        public func age(asOf now: Date) -> TimeInterval { now.timeIntervalSince(savedAt) }
    }

    private struct Entry: Codable {
        let savedAt: Date
        let items: [UnifiedMediaItem]
    }

    /// File URL for the single JSON blob (a `[key: Entry]` dictionary). `nil`
    /// ⇒ in-memory only (tests / previews / no-disk bootstrap).
    private let fileURL: URL?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// In-memory mirror, lazily hydrated from disk on first access.
    private var store: [String: Entry] = [:]
    private var loadedFromDisk = false

    /// - Parameter directory: directory to hold the snapshot file, or `nil` for
    ///   an in-memory-only store. The file is created lazily on first save.
    public init(directory: URL?) {
        self.fileURL = directory?.appendingPathComponent("UnifiedLibrarySnapshots.json")
    }

    /// Caches-directory location for the shared instance. `nil` (→ in-memory)
    /// only if Foundation can't hand us a caches URL, which is effectively never.
    public static func defaultDirectory() -> URL? {
        try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
    }

    /// The persisted catalog for `key`, regardless of age (the caller applies
    /// the staleness policy). `nil` when nothing has been captured for it yet.
    public func snapshot(for key: String) -> Snapshot? {
        hydrateIfNeeded()
        guard let entry = store[key] else { return nil }
        return Snapshot(items: entry.items, savedAt: entry.savedAt)
    }

    /// Capture `items` for `key`, stamped `at`. Replaces any prior snapshot for
    /// that key and writes the whole blob back atomically.
    public func save(_ items: [UnifiedMediaItem], for key: String, at date: Date) {
        hydrateIfNeeded()
        store[key] = Entry(savedAt: date, items: items)
        persist()
    }

    /// Drop the snapshots for specific keys — e.g. after a watched toggle, so the
    /// affected kind re-fetches fresh server state on the next cold read instead
    /// of repainting the stale badge. No-op for keys with nothing captured.
    public func clear(for keys: [String]) {
        hydrateIfNeeded()
        var changed = false
        for key in keys where store[key] != nil {
            store[key] = nil
            changed = true
        }
        if changed { persist() }
    }

    /// Drop every snapshot — sign-out or a connected-source change, where
    /// another account's catalog must not linger.
    public func clearAll() {
        store.removeAll()
        loadedFromDisk = true   // nothing to re-read; avoid a disk reload resurrecting it
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    // MARK: - Disk

    private func hydrateIfNeeded() {
        guard !loadedFromDisk else { return }
        loadedFromDisk = true
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? decoder.decode([String: Entry].self, from: data) {
            store = decoded
        }
    }

    private func persist() {
        guard let fileURL, let data = try? encoder.encode(store) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
