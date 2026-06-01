import Foundation

/// How items in a library are ordered when fetched and displayed.
///
/// Deliberately a flat enum (rather than a two-axis field × direction pair):
/// every "real" sort users care about is a single, opinionated pairing
/// ("Title A→Z", "Year — newest first", "Recently added"), and flattening
/// keeps the picker UI honest — no nested submenus, no nonsense pairings like
/// "Random descending."
public enum LibrarySort: String, Sendable, Hashable, Codable, CaseIterable {
    /// Alphabetical, A→Z. Plex's `titleSort:asc`.
    case titleAZ
    /// Alphabetical, Z→A. Plex's `titleSort:desc`.
    case titleZA
    /// Release year, newest first. Plex's `year:desc` (originally available
    /// date secondarily).
    case yearNewest
    /// Release year, oldest first.
    case yearOldest
    /// What was added to the server most recently. Plex's `addedAt:desc`.
    /// Useful as a default — surfaces new arrivals.
    case recentlyAdded
    /// Highest-rated first. Plex's `audienceRating:desc`.
    case ratingHighest
    /// Random. Plex supports this directly; refresh re-shuffles.
    case random

    /// What we pick when the user hasn't expressed a preference. *Recently
    /// added* tends to surface the most interesting titles on first open of a
    /// library that's already populated; "Title A→Z" is correct but boring.
    public static let `default`: LibrarySort = .recentlyAdded

    /// User-visible label, suitable for a `Picker` / `Menu` item.
    public var displayName: String {
        switch self {
        case .titleAZ:        return "Title (A–Z)"
        case .titleZA:        return "Title (Z–A)"
        case .yearNewest:     return "Year (newest)"
        case .yearOldest:     return "Year (oldest)"
        case .recentlyAdded:  return "Recently added"
        case .ratingHighest:  return "Top rated"
        case .random:         return "Random"
        }
    }

    /// SF Symbol that pairs with each sort, used in the picker.
    public var systemImage: String {
        switch self {
        case .titleAZ:        return "characters"
        case .titleZA:        return "characters"
        case .yearNewest:     return "calendar.badge.clock"
        case .yearOldest:     return "calendar"
        case .recentlyAdded:  return "clock.arrow.circlepath"
        case .ratingHighest:  return "star.fill"
        case .random:         return "shuffle"
        }
    }

    /// The `sort` query-parameter value Plex expects on
    /// `GET /library/sections/{key}/all`. Plex uses `field:direction` with
    /// `asc` / `desc`; `random` is a single token.
    public var plexParameter: String {
        switch self {
        case .titleAZ:        return "titleSort:asc"
        case .titleZA:        return "titleSort:desc"
        case .yearNewest:     return "year:desc"
        case .yearOldest:     return "year:asc"
        case .recentlyAdded:  return "addedAt:desc"
        case .ratingHighest:  return "audienceRating:desc"
        case .random:         return "random"
        }
    }
}
