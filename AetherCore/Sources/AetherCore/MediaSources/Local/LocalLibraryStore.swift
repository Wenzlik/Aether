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
        /// User corrections (#211). Any non-nil field **wins over** the TMDb
        /// match and the filename inference. `nil` when nothing is overridden.
        public var overrides: Overrides? = nil

        /// Per-field manual overrides. A nil field means "fall back" (to the
        /// TMDb match, then inference); a non-nil field is the user's value.
        public struct Overrides: Codable, Sendable, Hashable {
            public var title: String?
            public var year: Int?
            public var isEpisode: Bool?
            public var season: Int?
            public var episode: Int?
            public var overview: String?
            /// Filename of a custom poster in the store's `artworkDir`, if set.
            public var artworkFilename: String?

            public init(
                title: String? = nil, year: Int? = nil, isEpisode: Bool? = nil,
                season: Int? = nil, episode: Int? = nil, overview: String? = nil,
                artworkFilename: String? = nil
            ) {
                self.title = title; self.year = year; self.isEpisode = isEpisode
                self.season = season; self.episode = episode; self.overview = overview
                self.artworkFilename = artworkFilename
            }

            /// True when nothing is overridden — used to drop the struct to `nil`.
            public var isEmpty: Bool {
                title == nil && year == nil && isEpisode == nil && season == nil
                    && episode == nil && overview == nil && artworkFilename == nil
            }
        }

        // MARK: Effective values — override > TMDb match > inference.
        // Everything that displays or groups a local item reads these, so a
        // user correction propagates uniformly (#211).

        public var effectiveTitle: String { overrides?.title ?? metadata?.title ?? title }
        public var effectiveYear: Int? { overrides?.year ?? metadata?.year ?? year }
        public var effectiveOverview: String? { overrides?.overview ?? metadata?.overview }
        public var effectiveIsEpisode: Bool { overrides?.isEpisode ?? isEpisode }
        public var effectiveSeason: Int? { overrides?.season ?? season }
        public var effectiveEpisode: Int? { overrides?.episode ?? episode }
        /// True when a custom poster was set (resolved to a file URL by
        /// `LocalLibraryStore.artworkURL(for:)` — the filename lives in overrides).
        public var hasCustomArtwork: Bool { overrides?.artworkFilename != nil }
    }

    /// Attach (or clear) a TMDb match for an item, then persist. No-op if the
    /// item is gone.
    public func setMatch(_ metadata: TMDbMetadata?, for id: String) {
        hydrate()
        guard items[id] != nil else { return }
        items[id]?.metadata = metadata
        persist()
    }

    /// Store the user's manual corrections for an item, then persist (#211).
    /// An all-nil/`nil` value clears the overrides (back to match/inference).
    /// No-op if the item is gone.
    public func setOverrides(_ overrides: Item.Overrides?, for id: String) {
        hydrate()
        guard items[id] != nil else { return }
        items[id]?.overrides = (overrides?.isEmpty ?? true) ? nil : overrides
        persist()
    }

    /// Save custom poster bytes for an item into `artworkDir`, record the
    /// filename in its overrides, and persist. Returns the stored filename, or
    /// `nil` if the item is gone or the write failed (#211).
    @discardableResult
    public func setArtwork(_ data: Data, for id: String) -> String? {
        hydrate()
        guard items[id] != nil else { return nil }
        let name = "\(id).jpg"
        let url = artworkDir.appendingPathComponent(name)
        do { try data.write(to: url, options: .atomic) } catch { return nil }
        Self.excludeFromBackup(url)
        var overrides = items[id]?.overrides ?? Item.Overrides()
        overrides.artworkFilename = name
        items[id]?.overrides = overrides
        persist()
        return name
    }

    /// File URL of an item's custom poster, or `nil` if none was set.
    /// Nonisolated — pure path math over the immutable `artworkDir`.
    public nonisolated func artworkURL(for item: Item) -> URL? {
        guard let name = item.overrides?.artworkFilename else { return nil }
        return artworkDir.appendingPathComponent(name)
    }

    /// Media files live here; `mediaDir` is an immutable (`Sendable`) constant so
    /// it's readable synchronously off-actor for URL math.
    public nonisolated let mediaDir: URL
    /// Custom posters (#211) live here, separate from media; also iCloud-excluded.
    public nonisolated let artworkDir: URL
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
        self.artworkDir = root.appendingPathComponent("Artwork", isDirectory: true)
        self.indexURL = root.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: artworkDir, withIntermediateDirectories: true)
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

    /// Delete an item + its media file (and custom poster, if any).
    public func remove(_ id: String) {
        hydrate()
        if let item = items[id] {
            try? FileManager.default.removeItem(at: fileURL(for: item))
            if let artwork = artworkURL(for: item) {
                try? FileManager.default.removeItem(at: artwork)
            }
        }
        items[id] = nil
        persist()
    }

    /// Remove every item + its files (sign-out parity / reset).
    public func clearAll() {
        hydrate()
        for item in items.values {
            try? FileManager.default.removeItem(at: fileURL(for: item))
            if let artwork = artworkURL(for: item) {
                try? FileManager.default.removeItem(at: artwork)
            }
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
