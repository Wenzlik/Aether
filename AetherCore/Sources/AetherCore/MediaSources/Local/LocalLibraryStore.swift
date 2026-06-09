import Foundation

/// On-device store for the **Local Library** (#173): media files Aether owns,
/// imported from Files / the share sheet. Copies each file into a managed
/// directory in Application Support (excluded from iCloud backup), infers its
/// metadata via `TitleInference`, and persists a small JSON index across
/// launches. Pairs with `LocalMediaSource`, which maps these into `MediaItem`s.
public actor LocalLibraryStore {
    /// One imported file + its inferred metadata.
    public struct Item: Codable, Sendable, Hashable, Identifiable {
        public let id: String              // UUID — also the stored filename stem
        public let storedFilename: String  // file name within the media dir
        public let originalName: String    // the imported file's original name
        public let title: String
        public let year: Int?
        public let season: Int?
        public let episode: Int?
        public let isEpisode: Bool
        public let addedAt: Date
        /// TMDb match (poster / overview / canonical title), filled in after
        /// import when a TMDb key is configured (#210). `nil` until matched.
        public var metadata: TMDbMetadata? = nil
    }

    /// Attach (or clear) a TMDb match for an item, then persist. No-op if the
    /// item is gone.
    public func setMatch(_ metadata: TMDbMetadata?, for id: String) {
        hydrate()
        guard items[id] != nil else { return }
        items[id]?.metadata = metadata
        persist()
    }

    /// Media files live here; `mediaDir` is an immutable (`Sendable`) constant so
    /// it's readable synchronously off-actor for URL math.
    public nonisolated let mediaDir: URL
    private let indexURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var items: [String: Item] = [:]
    private var loaded = false

    /// - Parameter directory: the Local Library root. `nil` ⇒ a temporary
    ///   directory (tests). Production passes `defaultDirectory()`.
    public init(directory: URL? = LocalLibraryStore.defaultDirectory()) {
        let root = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("AetherLocalLibrary-\(UUID().uuidString)", isDirectory: true)
        self.mediaDir = root.appendingPathComponent("Media", isDirectory: true)
        self.indexURL = root.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
    }

    /// `Application Support/Aether/LocalLibrary` — persists across launches,
    /// not evicted like Caches. `nil` only if Foundation can't hand us the dir.
    public static func defaultDirectory() -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        return support
            .appendingPathComponent("Aether", isDirectory: true)
            .appendingPathComponent("LocalLibrary", isDirectory: true)
    }

    // MARK: - Reads

    /// Every imported item, newest first.
    public func allItems() -> [Item] {
        hydrate()
        return items.values.sorted { $0.addedAt > $1.addedAt }
    }

    public func count() -> Int {
        hydrate()
        return items.count
    }

    /// Absolute URL of an item's media file. Nonisolated — pure path math over
    /// the immutable `mediaDir`.
    public nonisolated func fileURL(for item: Item) -> URL {
        mediaDir.appendingPathComponent(item.storedFilename)
    }

    // MARK: - Writes

    /// Copy an external file into the managed store, infer its metadata, and
    /// persist. `sourceURL` may be a security-scoped document-picker URL.
    @discardableResult
    public func importFile(at sourceURL: URL) throws -> Item {
        hydrate()
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }

        let id = UUID().uuidString
        let ext = sourceURL.pathExtension
        let storedFilename = ext.isEmpty ? id : "\(id).\(ext)"
        let dest = mediaDir.appendingPathComponent(storedFilename)
        try FileManager.default.copyItem(at: sourceURL, to: dest)
        Self.excludeFromBackup(dest)

        let originalName = sourceURL.lastPathComponent
        let inferred = TitleInference(filename: originalName)
        let item = Item(
            id: id,
            storedFilename: storedFilename,
            originalName: originalName,
            title: inferred.title,
            year: inferred.year,
            season: inferred.season,
            episode: inferred.episode,
            isEpisode: inferred.isEpisode,
            addedAt: Date()
        )
        items[id] = item
        persist()
        return item
    }

    /// Delete an item + its media file.
    public func remove(_ id: String) {
        hydrate()
        if let item = items[id] {
            try? FileManager.default.removeItem(at: fileURL(for: item))
        }
        items[id] = nil
        persist()
    }

    /// Remove every item + its files (sign-out parity / reset).
    public func clearAll() {
        hydrate()
        for item in items.values {
            try? FileManager.default.removeItem(at: fileURL(for: item))
        }
        items.removeAll()
        persist()
    }

    // MARK: - Disk

    private func hydrate() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? decoder.decode([String: Item].self, from: data) else { return }
        items = decoded
    }

    private func persist() {
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private static func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)
    }
}
