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

        var continueWatching: [HomeFeed.ContinueWatchingEntry] = []
        for item in allItems {
            if let point = await resumeStore.point(for: item.id) {
                continueWatching.append(.init(item: item, resume: point))
            }
        }
        // Most recently updated first.
        continueWatching.sort { $0.resume.updatedAt > $1.resume.updatedAt }

        return HomeFeed(
            featured: featuredItems,
            continueWatching: continueWatching,
            libraries: librarySections
        )
    }
}
