import SwiftUI

/// Which rating source the poster badge displays.
public enum PosterRatingSource: String, CaseIterable, Sendable, Hashable {
    /// The server's own community/audience rating (Plex `audienceRating`, Jellyfin `CommunityRating`).
    case communityRating
    /// TMDb `vote_average` (0–10) when available for the title.
    case tmdb
    /// Hide the badge entirely.
    case none

    public var displayName: String {
        switch self {
        case .communityRating: return "Server Rating"
        case .tmdb:            return "TMDb"
        case .none:            return "Hide"
        }
    }
}

extension EnvironmentValues {
    /// Which rating appears on poster cards — injected at the app root from
    /// `PlaybackPreferencesStore.posterRatingSource` and read by poster components.
    @Entry public var posterRatingSource: PosterRatingSource = .communityRating
}
