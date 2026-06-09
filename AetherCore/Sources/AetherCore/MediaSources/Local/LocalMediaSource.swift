import Foundation

/// The Local Library as a `MediaSource` (#173). Maps `LocalLibraryStore` items
/// into `MediaItem`s and direct-plays the on-disk file — no transcode, no
/// downloads (it's already local).
///
/// Movies surface as flat playable titles; episodes are **grouped into show
/// containers** by their inferred series title (`TitleInference`), so a series
/// drills show → episodes like any server source. Two libraries (Movies / TV
/// Shows) so the Unified Library splits them by kind.
public actor LocalMediaSource: MediaSource {
    public nonisolated let id: MediaSourceID = .local
    public nonisolated let displayName: String = "Local Library"

    private let store: LocalLibraryStore

    private nonisolated var moviesLibraryID: Library.ID { .init(source: .local, rawValue: "movies") }
    private nonisolated var showsLibraryID: Library.ID { .init(source: .local, rawValue: "shows") }
    /// Show containers are synthetic — id = `show:<series title>`.
    private static let showPrefix = "show:"

    public init(store: LocalLibraryStore) {
        self.store = store
    }

    public func libraries() async throws -> [Library] {
        let items = await store.allItems()
        var libs: [Library] = []
        if items.contains(where: { !$0.isEpisode }) {
            libs.append(Library(id: moviesLibraryID, title: "Local Movies", kind: .movie))
        }
        if items.contains(where: { $0.isEpisode }) {
            libs.append(Library(id: showsLibraryID, title: "Local TV Shows", kind: .show))
        }
        return libs
    }

    public func items(in library: Library.ID) async throws -> [MediaItem] {
        let items = await store.allItems()
        if library == moviesLibraryID {
            return items.filter { !$0.isEpisode }.map { movieItem($0) }
        }
        if library == showsLibraryID {
            // One container per distinct inferred series title.
            let episodes = items.filter { $0.isEpisode }
            return Dictionary(grouping: episodes, by: { $0.title })
                .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
                .map { showContainer(series: $0.key, episodes: $0.value) }
        }
        return []
    }

    public func children(of id: MediaID) async throws -> [MediaItem] {
        guard id.source == self.id, id.rawValue.hasPrefix(Self.showPrefix) else { return [] }
        let series = String(id.rawValue.dropFirst(Self.showPrefix.count))
        let episodes = await store.allItems().filter { $0.isEpisode && $0.title == series }
        return sortedEpisodes(episodes).map { episodeItem($0, showID: id) }
    }

    public func item(for id: MediaID) async throws -> MediaItem? {
        guard id.source == self.id else { return nil }
        if id.rawValue.hasPrefix(Self.showPrefix) {
            let series = String(id.rawValue.dropFirst(Self.showPrefix.count))
            let episodes = await store.allItems().filter { $0.isEpisode && $0.title == series }
            return episodes.isEmpty ? nil : showContainer(series: series, episodes: episodes)
        }
        guard let stored = await store.allItems().first(where: { $0.id == id.rawValue }) else { return nil }
        return stored.isEpisode ? episodeItem(stored, showID: showID(for: stored.title)) : movieItem(stored)
    }

    /// No server transcoder — `resolvePlayback` uses the protocol default, which
    /// returns the item's `streamURL` (the on-disk file) for direct play.

    public nonisolated var supportsDownloads: Bool { false }

    // MARK: - Mapping

    private func showID(for series: String) -> MediaID {
        .init(source: id, rawValue: Self.showPrefix + series)
    }

    private func movieItem(_ item: LocalLibraryStore.Item) -> MediaItem {
        MediaItem(
            id: .init(source: id, rawValue: item.id),
            title: item.title,
            kind: .movie,
            year: item.year,
            streamURL: store.fileURL(for: item),
            dateAdded: item.addedAt
        )
    }

    private func showContainer(series: String, episodes: [LocalLibraryStore.Item]) -> MediaItem {
        let seasons = Set(episodes.compactMap(\.season))
        return MediaItem(
            id: showID(for: series),
            title: series,
            kind: .show,
            dateAdded: episodes.map(\.addedAt).max(),
            seasonCount: seasons.isEmpty ? nil : seasons.count,
            episodeCount: episodes.count
        )
    }

    private func episodeItem(_ item: LocalLibraryStore.Item, showID: MediaID) -> MediaItem {
        MediaItem(
            id: .init(source: id, rawValue: item.id),
            title: item.episode.map { "Episode \($0)" } ?? item.title,
            kind: .episode,
            streamURL: store.fileURL(for: item),
            seriesTitle: item.title,
            seasonNumber: item.season,
            episodeNumber: item.episode,
            parentID: showID,
            dateAdded: item.addedAt
        )
    }

    private func sortedEpisodes(_ episodes: [LocalLibraryStore.Item]) -> [LocalLibraryStore.Item] {
        episodes.sorted {
            ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0)
        }
    }
}
