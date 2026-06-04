import Foundation

/// What the **Discover** screen (tvOS) renders for the current source.
///
/// Discover replaces the Storage tab on Apple TV — Storage is a download
/// management surface that makes no sense on tvOS (no swipe gestures,
/// system-shared storage, persistent network), so the slot becomes a
/// content-discovery surface instead.
///
/// Three rails: a **hero pick** (one large randomly-selected artwork
/// banner), **Random Picks** (12 items shuffled across all libraries),
/// and **Recently Added** (newest items across all libraries). All
/// data comes from the same `MediaSource` APIs Home and Library already
/// use — no new endpoints. The randomness is computed once per build
/// and stays fixed for the session so the screen doesn't reshuffle on
/// every appearance.
public struct DiscoverFeed: Sendable, Equatable {
    /// The headline title — a single random pick from the library used as
    /// the hero artwork at the top of Discover. `nil` when the source
    /// has no items at all (signed in but empty library).
    public let heroPick: MediaItem?

    /// Up to N items pulled at random from across every library.
    /// Excludes `heroPick` so the same title doesn't appear twice.
    public let randomPicks: [MediaItem]

    /// Up to N items, newest first across every library. Uses each
    /// source's own "recently added" ordering (Plex's `addedAt:desc`,
    /// Jellyfin's `DateCreated`).
    public let recentlyAdded: [MediaItem]

    public init(
        heroPick: MediaItem?,
        randomPicks: [MediaItem],
        recentlyAdded: [MediaItem]
    ) {
        self.heroPick = heroPick
        self.randomPicks = randomPicks
        self.recentlyAdded = recentlyAdded
    }

    public static let empty = DiscoverFeed(heroPick: nil, randomPicks: [], recentlyAdded: [])

    /// True when there's nothing to show — every rail empty AND no hero.
    /// The view shows an empty-state placeholder in this case rather than
    /// a sea of blank scroll space.
    public var isEmpty: Bool {
        heroPick == nil && randomPicks.isEmpty && recentlyAdded.isEmpty
    }
}
