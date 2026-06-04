import Foundation

/// Builds a `DiscoverFeed` from a `MediaSource`. Source-agnostic — works
/// for Plex / Jellyfin (and any future source) without touching the
/// source's protocol; everything is composed from `libraries()` +
/// `items(in:)`.
///
/// **Randomness.** The shuffle is computed at build time with the
/// system PRNG, so two consecutive builds give different picks. The
/// view caches the built feed for the session (the same way HomeView
/// caches its `HomeFeed`) so the screen doesn't reshuffle on every
/// appearance — picks change when the user pulls to refresh or
/// re-launches.
public struct DiscoverFeedBuilder: Sendable {

    /// How many items to put in the Random Picks rail.
    public let randomCount: Int

    /// How many items to put in the Recently Added rail.
    public let recentCount: Int

    public init(randomCount: Int = 12, recentCount: Int = 12) {
        self.randomCount = randomCount
        self.recentCount = recentCount
    }

    public func build(source: any MediaSource) async throws -> DiscoverFeed {
        let libraries = try await source.libraries()

        // Gather every library's items, keeping per-library slices around
        // so we can interleave them later. Sequential await is fine — the
        // libraries list is small (handful at most), and the underlying
        // source clients pool their network connections.
        var perLibrary: [[MediaItem]] = []
        var allItems: [MediaItem] = []
        for library in libraries {
            let items = try await source.items(in: library.id)
            perLibrary.append(items)
            allItems.append(contentsOf: items)
        }

        // Deduplicate the flat list across libraries (a film cross-listed
        // in Movies + 4K Movies shouldn't double-count in the random rail).
        var seen: Set<MediaItem.ID> = []
        let uniqueItems = allItems.filter { seen.insert($0.id).inserted }

        // Hero: a single random pick. nil when the source has nothing.
        let hero = uniqueItems.randomElement()

        // Random Picks: shuffle, exclude the hero, take N.
        let randomPicks = uniqueItems
            .filter { $0.id != hero?.id }
            .shuffled()
            .prefix(randomCount)

        // Recently Added: each library's source-side sort already returns
        // newest first (Plex `addedAt:desc`, Jellyfin `DateCreated:desc`),
        // so the order *within* a library reflects recency. Without a
        // cross-library timestamp on `MediaItem` there's no way to
        // merge-sort by absolute date — the round-robin interleave below
        // gives a balanced "newest from each library" feel that always
        // surfaces every library's freshest title.
        let recentlyAdded = roundRobin(perLibrary: perLibrary, count: recentCount)
            .filter { $0.id != hero?.id }

        return DiscoverFeed(
            heroPick: hero,
            randomPicks: Array(randomPicks),
            recentlyAdded: recentlyAdded
        )
    }

    /// Interleaves each library's items round-robin (head of library 0,
    /// head of library 1, …, then back to library 0) until `count` is
    /// reached or every library's slice is drained.
    private func roundRobin(perLibrary: [[MediaItem]], count: Int) -> [MediaItem] {
        var queues = perLibrary
        var result: [MediaItem] = []
        var pulled = true
        while result.count < count && pulled {
            pulled = false
            for index in queues.indices {
                guard result.count < count else { break }
                guard !queues[index].isEmpty else { continue }
                result.append(queues[index].removeFirst())
                pulled = true
            }
        }
        return result
    }
}
