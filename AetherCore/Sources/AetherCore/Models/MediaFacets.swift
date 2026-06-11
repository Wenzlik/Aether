import Foundation

/// A server-side collection (Plex collection / Jellyfin BoxSet) — a curated
/// grouping of titles browsable from the Library (#273).
///
/// Deliberately **not** a `MediaItem` (and not `Codable` / persisted): a
/// collection is a browse facet, not a playable or downloadable title, and
/// modelling it as a `MediaItem.Kind` would ripple through every Kind switch
/// and the DownloadJob Codable surface for no benefit. `Hashable` because it
/// rides inside a `NavigationPath` route value.
public struct MediaCollection: Identifiable, Sendable, Hashable {
    /// Source-scoped id (Plex ratingKey / Jellyfin BoxSet id).
    public let id: MediaID
    public let title: String
    /// Number of titles inside, when the source reports it.
    public let childCount: Int?
    /// Cover art (poster/backdrop), tier-aware like any other artwork.
    public let artwork: ArtworkSource?

    public init(id: MediaID, title: String, childCount: Int? = nil, artwork: ArtworkSource? = nil) {
        self.id = id
        self.title = title
        self.childCount = childCount
        self.artwork = artwork
    }
}

/// The person facets the Library can browse by (#273).
public enum PersonKind: String, Sendable, Hashable, CaseIterable {
    case actor
    case director
}

/// A person (actor / director) as a browse facet — selecting one lists every
/// title they appear in. Same non-Codable/non-persisted rationale as
/// `MediaCollection`.
public struct MediaPerson: Identifiable, Sendable, Hashable {
    /// Source-scoped id (Plex tag id / Jellyfin person GUID).
    public let id: MediaID
    /// Which facet this person was listed under — Plex needs it to pick the
    /// right filter parameter when fetching their titles.
    public let kind: PersonKind
    public let name: String
    /// Headshot, when the source has one.
    public let artwork: ArtworkSource?

    public init(id: MediaID, kind: PersonKind, name: String, artwork: ArtworkSource? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.artwork = artwork
    }
}
