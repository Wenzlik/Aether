import Foundation

/// A source kind, ordered by **playback priority** (raw value = priority, lower
/// wins). Offline first (no bandwidth, works on a plane), then the servers.
/// `emby` is reserved for the upcoming connector.
public enum MediaSourceKind: Int, Comparable, Sendable, Hashable, Codable {
    case offline = 0
    case plex = 1
    case jellyfin = 2
    case emby = 3
    /// On-device Local Library — a server copy of the same title is preferred
    /// for playback when one exists.
    case local = 4
    /// Network shares — lowest priority: a metadata-rich server / Local copy is
    /// preferred when the same title exists there too (#214, #212).
    case smb = 5
    case dlna = 6
    /// An availability-only provider (Netflix link-out, #360). Never playable, so
    /// it sorts last and never wins `preferredSource`; it exists only so a
    /// Netflix-only title can be a `UnifiedSource` behind a card / Detail.
    case external = 7

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The streaming kind for a concrete `MediaSourceID`. Offline is derived
    /// separately (from the downloads store), not from an id. `nil` for kinds
    /// that aren't part of the unified priority (mock).
    public init?(streaming source: MediaSourceID) {
        switch source {
        case .plex:     self = .plex
        case .jellyfin: self = .jellyfin
        case .emby:     self = .emby
        case .local:    self = .local
        case .smb:      self = .smb
        case .dlna:     self = .dlna
        case .mock:     return nil
        // Availability-only (Netflix link-out, #360) — never a playback source.
        case .external: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .offline:  return "Offline"
        case .plex:     return "Plex"
        case .jellyfin: return "Jellyfin"
        case .emby:     return "Emby"
        case .local:    return "Local"
        case .smb:      return "SMB"
        case .dlna:     return "DLNA"
        case .external: return "Netflix"
        }
    }
}

/// One concrete source behind a unified title — the real per-source `MediaItem`
/// plus display metadata. Playback/download reuse `item` through the existing
/// `MediaSource`, so the unified layer adds no new playback path.
public struct UnifiedSource: Identifiable, Hashable, Sendable, Codable {
    public let kind: MediaSourceKind
    public let item: MediaItem
    public let serverName: String?
    public let playable: Bool

    public init(kind: MediaSourceKind, item: MediaItem, serverName: String? = nil, playable: Bool = true) {
        self.kind = kind
        self.item = item
        self.serverName = serverName
        self.playable = playable
    }

    /// Stable across a render — distinguishes the streaming vs offline copy of
    /// the same underlying item.
    public var id: String {
        "\(kind.rawValue):\(item.id.source.stableKey):\(item.id.rawValue)"
    }

    /// Short quality label for the Detail "Available Sources" rows, when known.
    public var quality: String? {
        item.mediaInfo?.videoResolution
    }
}

/// A title aggregated across every source that has it — the unit the unified UI
/// renders. The source becomes an implementation detail: one row, multiple
/// sources behind it.
public struct UnifiedMediaItem: Identifiable, Hashable, Sendable, Codable {
    public let id: String          // derived from the strongest shared external id
    public let title: String
    public let year: Int?
    public let overview: String?
    /// Default-tier (thumbnail) poster URL. For a specific tier use
    /// `posterURL(_:)`, which mints a server-resized URL from `artwork`.
    public let posterURL: URL?
    /// Default-tier (backdrop) URL. For a specific tier use `backdropURL(_:)`.
    public let backdropURL: URL?
    /// The artwork pinned to one deterministic source, so a unified title's image
    /// identity stays stable across source flips and can be re-minted at any
    /// `ArtworkTier` (e.g. a large Detail hero). `nil` when no source carries it.
    public let artwork: ArtworkSource?
    public let type: MediaItem.Kind
    /// Sorted by priority (offline → plex → jellyfin → emby).
    public let sources: [UnifiedSource]
    /// Catalogue genres (from the lead source) — Discover genre rails + Library
    /// genre filter.
    public let genres: [String]
    /// Community / audience rating (≈0–10) — Discover "Top Rated", Library sort.
    public let communityRating: Double?
    /// TMDb `vote_average` (0–10) when available — from `lead.tmdbRating`.
    public let tmdbRating: Double?
    /// Original release / premiere date — Home "Recently Released".
    public let releaseDate: Date?
    /// When the title was added to the library — Home "Recently Added".
    public let dateAdded: Date?

    public init(
        id: String,
        title: String,
        year: Int?,
        overview: String?,
        posterURL: URL?,
        backdropURL: URL?,
        type: MediaItem.Kind,
        sources: [UnifiedSource],
        artwork: ArtworkSource? = nil,
        genres: [String] = [],
        communityRating: Double? = nil,
        tmdbRating: Double? = nil,
        releaseDate: Date? = nil,
        dateAdded: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.year = year
        self.overview = overview
        self.posterURL = posterURL
        self.backdropURL = backdropURL
        self.artwork = artwork
        self.type = type
        self.sources = sources
        self.genres = genres
        self.communityRating = communityRating
        self.tmdbRating = tmdbRating
        self.releaseDate = releaseDate
        self.dateAdded = dateAdded
    }

    /// The rating to show on a poster badge given the user's `PosterRatingSource`
    /// preference. `.tmdb` falls back to `communityRating` when `tmdbRating` is nil.
    public func posterRating(source: PosterRatingSource) -> Double? {
        switch source {
        case .communityRating: return communityRating
        case .tmdb:            return tmdbRating ?? communityRating
        case .none:            return nil
        }
    }

    /// A server-resized poster URL at the given tier, minted from the pinned
    /// `artwork`. Falls back to the baked default-tier `posterURL` when no
    /// artwork source is pinned (e.g. offline-only titles).
    public func posterURL(_ tier: ArtworkTier) -> URL? {
        artwork?.posterURL(tier) ?? posterURL
    }

    /// A server-resized backdrop URL at the given tier (e.g. `.backdropLarge`
    /// for a full-screen Detail hero on tvOS / visionOS). Falls back to the
    /// baked default-tier `backdropURL`.
    public func backdropURL(_ tier: ArtworkTier) -> URL? {
        artwork?.backdropURL(tier) ?? backdropURL
    }

    /// The title's clearLogo URL, when the pinned artwork source carries one.
    public func logoURL(_ tier: ArtworkTier = .logo) -> URL? {
        artwork?.logoURL(tier)
    }

    /// The source playback should use: highest-priority playable source.
    public var preferredSource: UnifiedSource? {
        sources.filter(\.playable).min { $0.kind < $1.kind }
    }

    /// `true` when an offline (downloaded) copy exists.
    public var isDownloaded: Bool {
        sources.contains { $0.kind == .offline }
    }

    /// `true` when the title is watched on **any** of its sources (the source's
    /// own play state). Drives the watched checkmark on unified cards.
    public var isWatched: Bool {
        sources.contains { $0.item.isWatched }
    }

    /// `true` when the title is **fully** watched on any source — containers
    /// (shows) require every episode watched, so a partially-watched show is
    /// not badged (#260). This is what the card badge should use.
    public var isFullyWatched: Bool {
        sources.contains { $0.item.isFullyWatched }
    }

    /// The title's TMDb id, from whichever source carries one — the key for
    /// availability lookups (#360).
    public var tmdbID: String? {
        sources.lazy.compactMap { $0.item.guids.tmdb }.first
    }

    /// Runtime from whichever source reports one (the title is the same across
    /// sources, so the first non-nil wins). `nil` when no source carries it —
    /// common for shows, where runtime is per-episode. Used by recommendation
    /// filtering ("under 2 hours").
    public var runtime: Duration? {
        sources.lazy.compactMap { $0.item.runtime }.first
    }

    /// Whether this title is a series (picks the TMDb media type for lookups).
    public var isShow: Bool { type == .show }

    /// `true` when this title is *only* available externally (a Netflix-only
    /// discover/search result) — nothing in the user's library backs it, so its
    /// Detail offers "Play on Netflix" (link-out) instead of in-app playback.
    public var isExternalOnly: Bool {
        !sources.isEmpty && sources.allSatisfy { $0.kind == .external }
    }

    /// Build a Netflix-only title from a TMDb discover/search result (#360). The
    /// synthesized `MediaItem` has no `streamURL` (Aether never streams Netflix)
    /// and carries the TMDb id so it can be deduped against owned titles. Wrapped
    /// in a single, non-playable `.external` source so it flows through the
    /// normal card / navigation / Detail pipeline.
    public static func externalNetflix(from meta: TMDbMetadata, isShow: Bool) -> UnifiedMediaItem {
        let kind: MediaItem.Kind = isShow ? .show : .movie
        let raw = String(meta.tmdbID)
        let item = MediaItem(
            id: MediaID(source: .external(id: raw), rawValue: raw),
            title: meta.title,
            kind: kind,
            year: meta.year,
            summary: meta.overview,
            posterURL: meta.posterURL,
            backdropURL: meta.backdropURL,
            streamURL: nil,
            guids: MediaGuids(tmdb: raw)
        )
        return UnifiedMediaItem(
            id: "external.netflix.\(raw)",
            title: meta.title,
            year: meta.year,
            overview: meta.overview,
            posterURL: meta.posterURL,
            backdropURL: meta.backdropURL,
            type: kind,
            sources: [UnifiedSource(kind: .external, item: item, serverName: "Netflix", playable: false)]
        )
    }
}

/// The unified Home feed: deduplicated rails across all connected sources.
public struct UnifiedRails: Sendable, Equatable {
    public let continueWatching: [HomeFeed.ContinueWatchingEntry]
    public let movies: [UnifiedMediaItem]
    public let shows: [UnifiedMediaItem]
    public let downloaded: [UnifiedMediaItem]
    /// Newest titles by library add date — Home's "Recently Added" rail. Falls
    /// back to merge order when no source reports an add date.
    public let recentlyAdded: [UnifiedMediaItem]
    /// Newest titles by original release date — Home's "Recently Released" rail.
    public let recentlyReleased: [UnifiedMediaItem]
    /// True total movie / show counts across all sources (the `movies` / `shows`
    /// arrays above are capped to the rail limit; these are the full figures the
    /// Library tab shows in its section headers).
    public let movieCount: Int
    public let showCount: Int

    public init(
        continueWatching: [HomeFeed.ContinueWatchingEntry] = [],
        movies: [UnifiedMediaItem] = [],
        shows: [UnifiedMediaItem] = [],
        downloaded: [UnifiedMediaItem] = [],
        recentlyAdded: [UnifiedMediaItem] = [],
        recentlyReleased: [UnifiedMediaItem] = [],
        movieCount: Int = 0,
        showCount: Int = 0
    ) {
        self.continueWatching = continueWatching
        self.movies = movies
        self.shows = shows
        self.downloaded = downloaded
        self.recentlyAdded = recentlyAdded
        self.recentlyReleased = recentlyReleased
        self.movieCount = movieCount
        self.showCount = showCount
    }

    public static let empty = UnifiedRails()

    public var isEmpty: Bool {
        continueWatching.isEmpty && movies.isEmpty && shows.isEmpty && downloaded.isEmpty
            && recentlyAdded.isEmpty && recentlyReleased.isEmpty
    }
}

// Orderable by LibrarySort.sorted(_:) — fields already present (#294).
extension UnifiedMediaItem: LibrarySortable {}
