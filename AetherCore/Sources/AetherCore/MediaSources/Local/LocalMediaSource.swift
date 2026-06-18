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
        if items.contains(where: { !$0.effectiveIsEpisode }) {
            libs.append(Library(id: moviesLibraryID, title: "Local Movies", kind: .movie))
        }
        if items.contains(where: { $0.effectiveIsEpisode }) {
            libs.append(Library(id: showsLibraryID, title: "Local TV Shows", kind: .show))
        }
        return libs
    }

    public func items(in library: Library.ID) async throws -> [MediaItem] {
        let items = await store.allItems()
        if library == moviesLibraryID {
            return items.filter { !$0.effectiveIsEpisode }.map { movieItem($0) }
        }
        if library == showsLibraryID {
            // One container per distinct effective series title (user override >
            // TMDb match > inference), so corrections re-group correctly (#211).
            let episodes = items.filter { $0.effectiveIsEpisode }
            return Dictionary(grouping: episodes, by: { $0.effectiveTitle })
                .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
                .map { showContainer(series: $0.key, episodes: $0.value) }
        }
        return []
    }

    public func children(of id: MediaID) async throws -> [MediaItem] {
        guard id.source == self.id, id.rawValue.hasPrefix(Self.showPrefix) else { return [] }
        let series = String(id.rawValue.dropFirst(Self.showPrefix.count))
        let episodes = await store.allItems().filter { $0.effectiveIsEpisode && $0.effectiveTitle == series }
        return sortedEpisodes(episodes).map { episodeItem($0, showID: id) }
    }

    public func item(for id: MediaID) async throws -> MediaItem? {
        guard id.source == self.id else { return nil }
        if id.rawValue.hasPrefix(Self.showPrefix) {
            let series = String(id.rawValue.dropFirst(Self.showPrefix.count))
            let episodes = await store.allItems().filter { $0.effectiveIsEpisode && $0.effectiveTitle == series }
            return episodes.isEmpty ? nil : showContainer(series: series, episodes: episodes)
        }
        guard let stored = await store.allItems().first(where: { $0.id == id.rawValue }) else { return nil }
        return stored.effectiveIsEpisode ? episodeItem(stored, showID: showID(for: stored.effectiveTitle)) : movieItem(stored)
    }

    /// No server transcoder — `resolvePlayback` uses the protocol default, which
    /// returns the item's `streamURL` (the on-disk file) for direct play.

    public nonisolated var supportsDownloads: Bool { false }

    // MARK: - Mapping

    private func showID(for series: String) -> MediaID {
        .init(source: id, rawValue: Self.showPrefix + series)
    }

    private func movieItem(_ item: LocalLibraryStore.Item) -> MediaItem {
        return MediaItem(
            id: .init(source: id, rawValue: item.id),
            title: item.effectiveTitle,
            kind: .movie,
            year: item.effectiveYear,
            summary: item.effectiveOverview,
            posterURL: store.artworkURL(for: item) ?? item.metadata?.posterURL,
            backdropURL: item.metadata?.backdropURL,
            streamURL: store.fileURL(for: item),
            tmdbRating: item.metadata?.rating,
            dateAdded: item.addedAt
        )
    }

    private func showContainer(series: String, episodes: [LocalLibraryStore.Item]) -> MediaItem {
        // `series` is already the effective title (the grouping key), so it
        // reflects any override. Artwork/overview come from the first episode
        // that has them — custom poster wins over the TMDb match.
        let seasons = Set(episodes.compactMap(\.effectiveSeason))
        let poster = episodes.compactMap { store.artworkURL(for: $0) }.first
            ?? episodes.compactMap { $0.metadata?.posterURL }.first
        return MediaItem(
            id: showID(for: series),
            title: series,
            kind: .show,
            summary: episodes.compactMap(\.effectiveOverview).first,
            posterURL: poster,
            backdropURL: episodes.compactMap { $0.metadata?.backdropURL }.first,
            tmdbRating: episodes.compactMap { $0.metadata?.rating }.first,
            dateAdded: episodes.map(\.addedAt).max(),
            seasonCount: seasons.isEmpty ? nil : seasons.count,
            episodeCount: episodes.count
        )
    }

    private func episodeItem(_ item: LocalLibraryStore.Item, showID: MediaID) -> MediaItem {
        return MediaItem(
            id: .init(source: id, rawValue: item.id),
            title: item.effectiveEpisode.map { "Episode \($0)" } ?? item.effectiveTitle,
            kind: .episode,
            summary: item.effectiveOverview,
            posterURL: store.artworkURL(for: item) ?? item.metadata?.posterURL,
            streamURL: store.fileURL(for: item),
            seriesTitle: item.effectiveTitle,
            seasonNumber: item.effectiveSeason,
            episodeNumber: item.effectiveEpisode,
            parentID: showID,
            dateAdded: item.addedAt
        )
    }

    private func sortedEpisodes(_ episodes: [LocalLibraryStore.Item]) -> [LocalLibraryStore.Item] {
        episodes.sorted {
            ($0.effectiveSeason ?? 0, $0.effectiveEpisode ?? 0) < ($1.effectiveSeason ?? 0, $1.effectiveEpisode ?? 0)
        }
    }
}
