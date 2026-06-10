import Foundation

/// Builds a `HomeFeed` from a `MediaSource` and a `ResumeStore`.
///
/// Source-agnostic — works for the mock source today and for Plex / Synology in 0.2.
/// The featured strategy is intentionally pluggable so individual sources can
/// override it (Plex has its own "On Deck"; the mock source provides an explicit
/// curated list).
public struct HomeFeedBuilder: Sendable {
    public init() {}

    /// Build the feed.
    /// - Parameters:
    ///   - source: the media source to query.
    ///   - resumeStore: the resume point store to intersect against.
    ///   - featured: an optional pre-curated featured list. The mock source
    ///     passes its `featuredItems`; other sources may pass `nil` and let the
    ///     builder pick reasonable defaults (currently: first N items overall).
    public func build(
        source: any MediaSource,
        resumeStore: ResumeStore,
        featured: [MediaItem]? = nil,
        featuredFallbackCount: Int = 4
    ) async throws -> HomeFeed {
        let libraries = try await source.libraries()

        var librarySections: [HomeFeed.LibrarySection] = []
        var allItems: [MediaItem] = []
        librarySections.reserveCapacity(libraries.count)

        for library in libraries {
            let items = try await source.items(in: library.id)
            librarySections.append(.init(library: library, items: items))
            allItems.append(contentsOf: items)
        }

        let featuredItems: [MediaItem] = {
            if let featured, !featured.isEmpty { return featured }
            return Array(allItems.prefix(featuredFallbackCount))
        }()

        let continueWatching = await continueWatchingEntries(
            source: source, allItems: allItems, resumeStore: resumeStore
        )

        return HomeFeed(
            featured: featuredItems,
            continueWatching: continueWatching,
            libraries: librarySections
        )
    }

    /// Continue Watching / Next Up across movies **and TV** (#243).
    ///
    /// Earlier this only intersected resume points with the top-level library
    /// items (movies + show *containers*), so a partially-watched **episode** —
    /// whose resume point is keyed by the episode id, and which lives as a child
    /// of a show — never surfaced. Here we walk the resume points themselves:
    /// movies resolve from the already-fetched library items; anything else is
    /// hydrated via `item(for:)` (bounded by how much the user has actually
    /// watched, not the library size). Episodes are grouped by their show and
    /// only the **best** one per show is surfaced, so a show appears once.
    private func continueWatchingEntries(
        source: any MediaSource,
        allItems: [MediaItem],
        resumeStore: ResumeStore
    ) async -> [HomeFeed.ContinueWatchingEntry] {
        let points = await resumeStore.allPoints()
        guard !points.isEmpty else { return [] }
        let topLevel = Dictionary(allItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var entries: [HomeFeed.ContinueWatchingEntry] = []
        // Resumable episodes keyed by their show, so we surface one per show.
        var episodesByShow: [MediaID: [(item: MediaItem, resume: ResumePoint)]] = [:]

        for point in points {
            if let item = topLevel[point.mediaID] {
                if !item.kind.isContainer { entries.append(.init(item: item, resume: point)) }
            } else if let item = try? await source.item(for: point.mediaID) {
                if item.kind == .episode, let showID = item.parentID {
                    episodesByShow[showID, default: []].append((item, point))
                } else if !item.kind.isContainer {
                    entries.append(.init(item: item, resume: point))
                }
            }
        }

        // One entry per show: the episode the user is most likely to continue.
        for (_, episodes) in episodesByShow {
            if let best = episodes.max(by: Self.episodeRanksLower) {
                entries.append(.init(item: best.item, resume: best.resume))
            }
        }

        // Most recently active first, across movies + shows.
        entries.sort { $0.resume.updatedAt > $1.resume.updatedAt }
        return entries
    }

    /// `true` when `a` should rank **below** `b` for "which episode of this show
    /// to resume": older activity loses, then older season, then older episode
    /// (#243). Used with `max(by:)`, which then returns the top-priority episode.
    private static func episodeRanksLower(
        _ a: (item: MediaItem, resume: ResumePoint),
        _ b: (item: MediaItem, resume: ResumePoint)
    ) -> Bool {
        if a.resume.updatedAt != b.resume.updatedAt { return a.resume.updatedAt < b.resume.updatedAt }
        if (a.item.seasonNumber ?? 0) != (b.item.seasonNumber ?? 0) {
            return (a.item.seasonNumber ?? 0) < (b.item.seasonNumber ?? 0)
        }
        return (a.item.episodeNumber ?? 0) < (b.item.episodeNumber ?? 0)
    }
}
