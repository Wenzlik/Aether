import Foundation

/// The Local Library as a `MediaSource` (#173). Maps `LocalLibraryStore` items
/// into `MediaItem`s and direct-plays the on-disk file — no transcode, no
/// downloads (it's already local). v1 surfaces every imported file as a flat
/// playable title; TV show/season grouping is a fast-follow.
public actor LocalMediaSource: MediaSource {
    public nonisolated let id: MediaSourceID = .local
    public nonisolated let displayName: String = "Local Library"

    private let store: LocalLibraryStore

    /// Stable library id for the single v1 library.
    private nonisolated var libraryID: Library.ID { .init(source: .local, rawValue: "all") }

    public init(store: LocalLibraryStore) {
        self.store = store
    }

    public func libraries() async throws -> [Library] {
        [Library(id: libraryID, title: "Local Library", kind: .movie)]
    }

    public func items(in library: Library.ID) async throws -> [MediaItem] {
        guard library == libraryID else { return [] }
        return await store.allItems().map { map($0) }
    }

    public func children(of id: MediaID) async throws -> [MediaItem] {
        []   // flat in v1 — no show/season hierarchy yet
    }

    public func item(for id: MediaID) async throws -> MediaItem? {
        guard id.source == self.id else { return nil }
        return await store.allItems().first { $0.id == id.rawValue }.map { map($0) }
    }

    /// No server transcoder — `resolvePlayback` uses the protocol default, which
    /// returns the item's `streamURL` (the on-disk file) for direct play.

    public nonisolated var supportsDownloads: Bool { false }

    // MARK: - Mapping

    private func map(_ item: LocalLibraryStore.Item) -> MediaItem {
        // Episodes carry their S/E into the title until grouping lands; the
        // unified kind stays `.movie` so flat items list under one library.
        let displayTitle: String
        if item.isEpisode, let s = item.season, let e = item.episode {
            displayTitle = "\(item.title) · S\(s)E\(e)"
        } else {
            displayTitle = item.title
        }
        return MediaItem(
            id: .init(source: id, rawValue: item.id),
            title: displayTitle,
            kind: .movie,
            year: item.year,
            streamURL: store.fileURL(for: item),
            dateAdded: item.addedAt
        )
    }
}
