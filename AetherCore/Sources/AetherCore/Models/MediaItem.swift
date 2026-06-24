import Foundation

extension String {
    /// Trimmed of surrounding whitespace, or `nil` if the result is empty.
    /// Used by the source connectors to coalesce blank server strings
    /// (content rating, codec labels) into a clean optional.
    var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// A unified, source-agnostic media item.
///
/// Both Plex and Synology connectors map their native types into `MediaItem`
/// so views, navigation, and playback never have to branch on the source.
public struct MediaItem: Identifiable, Hashable, Sendable, Codable {
    public let id: MediaID
    public let title: String
    public let kind: Kind
    public let year: Int?
    public let runtime: Duration?
    public let summary: String?
    public let posterURL: URL?
    public let backdropURL: URL?
    public let streamURL: URL?
    public let audioTracks: [MediaAudioTrack]
    public let selectedAudioTrackID: String?
    public let subtitleTracks: [MediaSubtitleTrack]
    /// The selected subtitle stream id. `nil` means subtitles are **off** —
    /// the user-facing "Off" row in the picker. A non-nil id matches one of
    /// `subtitleTracks`.
    public let selectedSubtitleTrackID: String?
    /// `true` once a track selection was APPLIED on top of the source's own
    /// defaults (picker tap, app-default language seeding, next-episode carry)
    /// — sources that must transcode to honor a pick key off this (#68).
    /// Optional so persisted catalogs from before the field decode as nil.
    public let explicitTrackSelection: Bool?
    /// Plex Part id (e.g. `"17905"`). Surfaces `Media.Part.id` so the playback
    /// pipeline can `PUT /library/parts/{partId}?audioStreamID=…` before
    /// asking Plex for a decision — the canonical way to set the active
    /// streams, instead of jamming ids onto the start.m3u8 URL.
    public let partID: String?
    /// Tokenised URL of the source file itself — for Plex this is the
    /// full Part path (`/library/parts/{partId}/{ts}/{filename}`) with
    /// `X-Plex-Token` appended. Independent of `streamURL`: that field
    /// holds the URL Aether plays from (file URL for direct-play
    /// containers, transcode placeholder for others), whereas
    /// `originalFileURL` is *always* the raw file URL — used by the
    /// download pipeline at Original quality so the server doesn't
    /// transcode (which fails with HTTP 400 on remote endpoints when
    /// using `protocol=http`). `nil` for items without a downloadable
    /// raw file (Mock, future Local Library where streamURL already is
    /// the file).
    public let originalFileURL: URL?
    /// Pre-playback media info shown on Detail (source codec, resolution,
    /// bitrate, HDR badge). Filled by the source layer from server metadata.
    public let mediaInfo: MediaInfo?
    /// For episodes: the parent series's display title (Plex's
    /// `grandparentTitle`). `nil` for movies and standalone clips.
    /// Surfaced in rails / Storage rows so the user reads
    /// "Breaking Bad" alongside the episode name instead of just "Pilot".
    public let seriesTitle: String?
    /// For episodes: parent season number (Plex's `parentIndex`).
    /// Combined with `episodeNumber` to render the "S1E1" prefix.
    public let seasonNumber: Int?
    /// For episodes: the episode's own number within its season (Plex's
    /// `index`).
    public let episodeNumber: Int?
    /// The Detail-screen quality picker selection. Defaults to `.original`
    /// (Direct Play priority) — every other choice biases toward a transcode.
    public let selectedQuality: PlaybackQuality

    /// External catalogue IDs (TMDB / IMDB / TVDB) parsed from the source's
    /// metadata. The basis for Unified Library deduplication — the same title on
    /// Plex, Jellyfin, and offline shares these. Empty when the source didn't
    /// provide any (then dedup falls back to title + year).
    public let guids: MediaGuids
    /// Whether the user has already watched this item, per the *source's* play
    /// state (Plex `viewCount > 0`, Jellyfin `UserData.Played`). Drives the
    /// "watched" checkmark on posters / episode rows; reflects watched-anywhere,
    /// not just in-Aether playback.
    public let isWatched: Bool
    /// Whether the item is favorited on the *source* (Jellyfin
    /// `UserData.IsFavorite`). Server-synced where supported; always `false` on
    /// sources without a favorite concept (Plex has none). Drives the Detail
    /// favorite star.
    public let isFavorite: Bool
    /// For episodes: the parent **season**'s id (Plex `parentRatingKey`,
    /// Jellyfin `ParentId`). Lets Auto-Play-Next fetch the season's episodes and
    /// pick the next one. `nil` for movies / when the source didn't provide it.
    public let parentID: MediaID?
    /// Catalogue genres (e.g. "Sci-Fi", "Drama") — drives Discover genre rails.
    public let genres: [String]
    /// Top-billed cast and key crew, in the source's billing order. Drives the
    /// Detail "Cast & Crew" rail. Empty when the source provided none.
    public let cast: [CastMember]
    /// Community / audience rating (≈0–10) when the source provides one — for
    /// "Top Rated". `nil` when unknown.
    public let communityRating: Double?
    /// TMDb `vote_average` (0–10) when available. Populated for Local Library
    /// items via `TMDbMetadata.rating`; for Plex/Jellyfin items it is fetched
    /// lazily in Detail and is `nil` in the list view unless pre-populated.
    public let tmdbRating: Double?
    /// The user's **personal** rating (Plex `userRating`, 0–10) when the source
    /// supports it and the item has been rated. `nil` = unrated. Drives the
    /// Detail star control; set via `MediaSource.setRating`.
    public let userRating: Double?
    /// Age / content classification as the source labels it — Plex
    /// `contentRating` / Jellyfin `OfficialRating` (e.g. "PG-13", "TV-MA",
    /// "15"). Rendered as a boxed badge in the Detail metadata line. `nil`
    /// when the source didn't provide one.
    public let contentRating: String?
    /// Original release / premiere date — for "Recently Released".
    public let releaseDate: Date?
    /// When the item was added to the library — for an accurate "Recently Added".
    public let dateAdded: Date?
    /// For shows: number of seasons (Plex `childCount` / Jellyfin `ChildCount`).
    public let seasonCount: Int?
    /// For shows: total episodes (Plex `leafCount` / Jellyfin `RecursiveItemCount`).
    public let episodeCount: Int?
    /// For shows: the final year if the series has ended; `nil` = ongoing /
    /// unknown.
    public let endYear: Int?
    /// For shows: whether the series is still airing. `true` ⇒ render the year
    /// as "2011–Present"; `false` ⇒ ended; `nil` ⇒ unknown (Plex doesn't
    /// expose a status, so we don't guess). Jellyfin maps it from `Status`.
    public let isContinuing: Bool?
    /// For a **season** (or show): how many of its episodes are still unwatched
    /// (Plex `leafCount − viewedLeafCount`, Jellyfin `UserData.UnplayedItemCount`).
    /// Lets Series Detail land its "Next Up" / On Deck on the season the user is
    /// actually in, without fetching every episode. `nil` when unknown.
    public let unwatchedEpisodeCount: Int?
    /// The title's artwork as a source + reference, able to mint a server-resized
    /// URL at any `ArtworkTier`. `posterURL`/`backdropURL` above are the baked
    /// defaults (thumbnail / backdrop); call sites that want a different size
    /// (e.g. a full-screen hero) use `artwork?.backdropURL(.backdropLarge)`.
    /// `nil` for sources/items without it (offline, mock).
    public let artwork: ArtworkSource?

    public init(
        id: MediaID,
        title: String,
        kind: Kind,
        year: Int? = nil,
        runtime: Duration? = nil,
        summary: String? = nil,
        posterURL: URL? = nil,
        backdropURL: URL? = nil,
        streamURL: URL? = nil,
        audioTracks: [MediaAudioTrack] = [],
        selectedAudioTrackID: String? = nil,
        subtitleTracks: [MediaSubtitleTrack] = [],
        selectedSubtitleTrackID: String? = nil,
        explicitTrackSelection: Bool? = nil,
        partID: String? = nil,
        originalFileURL: URL? = nil,
        mediaInfo: MediaInfo? = nil,
        seriesTitle: String? = nil,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        selectedQuality: PlaybackQuality = .original,
        guids: MediaGuids = MediaGuids(),
        isWatched: Bool = false,
        isFavorite: Bool = false,
        parentID: MediaID? = nil,
        genres: [String] = [],
        cast: [CastMember] = [],
        communityRating: Double? = nil,
        tmdbRating: Double? = nil,
        userRating: Double? = nil,
        contentRating: String? = nil,
        releaseDate: Date? = nil,
        dateAdded: Date? = nil,
        seasonCount: Int? = nil,
        episodeCount: Int? = nil,
        endYear: Int? = nil,
        isContinuing: Bool? = nil,
        unwatchedEpisodeCount: Int? = nil,
        artwork: ArtworkSource? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.year = year
        self.runtime = runtime
        self.summary = summary
        self.posterURL = posterURL
        self.backdropURL = backdropURL
        self.streamURL = streamURL
        self.audioTracks = audioTracks
        self.selectedAudioTrackID = selectedAudioTrackID ?? audioTracks.first(where: \.isSelected)?.id
        self.subtitleTracks = subtitleTracks
        self.selectedSubtitleTrackID = selectedSubtitleTrackID ?? subtitleTracks.first(where: \.isSelected)?.id
        self.explicitTrackSelection = explicitTrackSelection
        self.partID = partID
        self.originalFileURL = originalFileURL
        self.mediaInfo = mediaInfo
        self.seriesTitle = seriesTitle
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.selectedQuality = selectedQuality
        self.guids = guids
        self.isWatched = isWatched
        self.isFavorite = isFavorite
        self.parentID = parentID
        self.genres = genres
        self.cast = cast
        self.communityRating = communityRating
        self.tmdbRating = tmdbRating
        self.userRating = userRating
        self.contentRating = contentRating
        self.releaseDate = releaseDate
        self.dateAdded = dateAdded
        self.seasonCount = seasonCount
        self.episodeCount = episodeCount
        self.endYear = endYear
        self.isContinuing = isContinuing
        self.unwatchedEpisodeCount = unwatchedEpisodeCount
        self.artwork = artwork
    }

    /// Display label that's smart about episodes vs movies. For an
    /// episode with all the context the source provided, renders
    /// `"Breaking Bad · S1E1 · Pilot"`. For a movie it's just `title`.
    /// Edge cases gracefully degrade: missing series → `"S1E1 · Pilot"`,
    /// missing numbers → `"Breaking Bad · Pilot"`. Surfaced in rails
    /// and Storage rows where the bare episode name would read as
    /// ambiguous out of context.
    public var displayTitle: String {
        guard kind == .episode else { return title }
        let episodeCode: String? = {
            guard let seasonNumber, let episodeNumber else { return nil }
            return "S\(seasonNumber)E\(episodeNumber)"
        }()
        let parts: [String] = [seriesTitle, episodeCode, title].compactMap { $0 }
        return parts.joined(separator: " · ")
    }

    public var selectedAudioTrack: MediaAudioTrack? {
        guard let selectedAudioTrackID else { return nil }
        return audioTracks.first { $0.id == selectedAudioTrackID }
    }

    public var selectedSubtitleTrack: MediaSubtitleTrack? {
        guard let selectedSubtitleTrackID else { return nil }
        return subtitleTracks.first { $0.id == selectedSubtitleTrackID }
    }

    /// A server-resized poster URL at the given tier, minted from `artwork`.
    /// Falls back to the baked default-tier `posterURL` (offline / mock items).
    public func posterURL(_ tier: ArtworkTier) -> URL? {
        artwork?.posterURL(tier) ?? posterURL
    }

    /// A server-resized backdrop URL at the given tier (e.g. `.backdropLarge`
    /// for a full-screen hero, `.still` for an episode row). Falls back to the
    /// baked default-tier `backdropURL`.
    public func backdropURL(_ tier: ArtworkTier) -> URL? {
        artwork?.backdropURL(tier) ?? backdropURL
    }

    /// The title's clearLogo URL (transparent wordmark for the Detail hero),
    /// when the source carries one. No baked fallback — most titles have none.
    public func logoURL(_ tier: ArtworkTier = .logo) -> URL? {
        artwork?.logoURL(tier)
    }

    /// The rating to show on a poster badge given the user's `PosterRatingSource`
    /// preference. `.tmdb` falls back to `communityRating` when `tmdbRating` is
    /// nil (server items whose TMDb rating is fetched lazily in Detail only).
    public func posterRating(source: PosterRatingSource) -> Double? {
        switch source {
        case .communityRating: return communityRating
        case .tmdb:            return tmdbRating ?? communityRating
        case .none:            return nil
        }
    }

    /// Copy preserving every field except those explicitly overridden. Keeps
    /// the selection transforms below from drifting as new fields are added.
    private func copy(
        audioTracks: [MediaAudioTrack]? = nil,
        selectedAudioTrackID: String?? = nil,
        subtitleTracks: [MediaSubtitleTrack]? = nil,
        selectedSubtitleTrackID: String?? = nil,
        explicitTrackSelection: Bool?? = nil,
        selectedQuality: PlaybackQuality? = nil
    ) -> MediaItem {
        MediaItem(
            id: id,
            title: title,
            kind: kind,
            year: year,
            runtime: runtime,
            summary: summary,
            posterURL: posterURL,
            backdropURL: backdropURL,
            streamURL: streamURL,
            audioTracks: audioTracks ?? self.audioTracks,
            selectedAudioTrackID: selectedAudioTrackID ?? self.selectedAudioTrackID,
            subtitleTracks: subtitleTracks ?? self.subtitleTracks,
            selectedSubtitleTrackID: selectedSubtitleTrackID ?? self.selectedSubtitleTrackID,
            explicitTrackSelection: explicitTrackSelection ?? self.explicitTrackSelection,
            partID: partID,
            originalFileURL: originalFileURL,
            mediaInfo: mediaInfo,
            seriesTitle: seriesTitle,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            selectedQuality: selectedQuality ?? self.selectedQuality,
            guids: guids,
            isWatched: isWatched,
            isFavorite: isFavorite,
            parentID: parentID,
            genres: genres,
            cast: cast,
            communityRating: communityRating,
            tmdbRating: tmdbRating,
            userRating: userRating,
            contentRating: contentRating,
            releaseDate: releaseDate,
            dateAdded: dateAdded,
            seasonCount: seasonCount,
            episodeCount: episodeCount,
            endYear: endYear,
            isContinuing: isContinuing,
            unwatchedEpisodeCount: unwatchedEpisodeCount,
            artwork: artwork
        )
    }

    /// Whether playback start/seek is handled by the server (Plex universal
    /// transcode) rather than the local `AVPlayer`. A transcode session emits
    /// HLS from a fixed start offset, so seeking the player into a from-zero
    /// transcode requests segments the server never produced — surfacing as
    /// `NSURLErrorDomain -1008`. For these we bake the start position into the
    /// URL (`offset`) instead of seeking. Direct-play files seek client-side.
    public var isServerTranscode: Bool {
        guard let streamURL else { return false }
        // An HLS playlist (.m3u8) means the server is transcoding / remuxing —
        // true for both Plex (`…/start.m3u8`) and Jellyfin (`…/master.m3u8`).
        // Direct-play URLs are real files (.mkv/.mp4) or Jellyfin's `…/stream`,
        // none of which are .m3u8.
        return streamURL.pathExtension.lowercased() == "m3u8"
            || streamURL.path.contains("/transcode/universal/start")
    }

    /// Return a copy with this audio track marked as selected. Pure state
    /// update — the playback URL is rebuilt by the source's `resolvePlayback`
    /// when the user actually presses Play (PUT the selection to the Part,
    /// then ask the server for a fresh decision).
    public func selectingAudioTrack(_ track: MediaAudioTrack) -> MediaItem {
        let nextTracks = audioTracks.map { $0.withSelection($0.id == track.id) }
        return copy(audioTracks: nextTracks, selectedAudioTrackID: track.id,
                    explicitTrackSelection: true)
    }

    /// Return a copy with `track` selected as the burned-in / muxed subtitle,
    /// or subtitles turned **off** when `track` is `nil`. Like
    /// `selectingAudioTrack`, this is a pure state update; the source layer
    /// PUTs the selection to the Part at play time.
    public func selectingSubtitleTrack(_ track: MediaSubtitleTrack?) -> MediaItem {
        let nextTracks = subtitleTracks.map { $0.withSelection($0.id == track?.id) }
        return copy(subtitleTracks: nextTracks, selectedSubtitleTrackID: .some(track?.id),
                    explicitTrackSelection: true)
    }

    /// Return a copy with the chosen playback quality. `.original` keeps Direct
    /// Play priority; everything else biases the request toward a transcode.
    public func selectingQuality(_ quality: PlaybackQuality) -> MediaItem {
        copy(selectedQuality: quality)
    }

    public enum Kind: String, Sendable, Hashable {
        case movie
        case episode
        case show
        case season

        /// Whether this kind is a container browsed into for children (a show's
        /// seasons, a season's episodes) rather than played directly.
        public var isContainer: Bool {
            self == .show || self == .season
        }
    }

    /// Whether this item should display as **fully watched**. Leaves use the raw
    /// `isWatched` flag; **containers** (shows / seasons) require that every
    /// episode is watched (`unwatchedEpisodeCount == 0`) — the raw source flag
    /// can read "watched" before the whole show is (#260). An unknown count
    /// (`nil`) ⇒ not fully watched, so a partially-watched show is never badged.
    public var isFullyWatched: Bool {
        if kind.isContainer { return (unwatchedEpisodeCount ?? 1) == 0 }
        return isWatched
    }
}

/// External catalogue identifiers for a title — the basis for recognising the
/// same movie/show across sources (Plex, Jellyfin, offline) in Unified Library.
public struct MediaGuids: Hashable, Sendable, Codable {
    public var tmdb: String?
    public var imdb: String?
    public var tvdb: String?

    public init(tmdb: String? = nil, imdb: String? = nil, tvdb: String? = nil) {
        self.tmdb = tmdb
        self.imdb = imdb
        self.tvdb = tvdb
    }

    /// `true` when there's no external ID to match on (dedup falls back to
    /// title + year).
    public var isEmpty: Bool { tmdb == nil && imdb == nil && tvdb == nil }

    /// Build from provider-prefixed strings like `tmdb://12345`,
    /// `imdb://tt0083658`, `tvdb://78874` (Plex `Guid` entries). Unknown schemes
    /// are ignored; the first value per provider wins.
    public init(guidStrings: [String]) {
        for raw in guidStrings {
            let lower = raw.lowercased()
            func value(_ scheme: String) -> String? {
                guard lower.hasPrefix(scheme) else { return nil }
                let v = String(raw.dropFirst(scheme.count))
                return v.isEmpty ? nil : v
            }
            if tmdb == nil, let v = value("tmdb://") { tmdb = v }
            if imdb == nil, let v = value("imdb://") { imdb = v }
            if tvdb == nil, let v = value("tvdb://") { tvdb = v }
        }
    }
}

public struct MediaAudioTrack: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let title: String
    public let languageCode: String?
    public let codec: String?
    public let channels: Int?
    public let isSelected: Bool

    public init(
        id: String,
        title: String,
        languageCode: String? = nil,
        codec: String? = nil,
        channels: Int? = nil,
        isSelected: Bool = false
    ) {
        self.id = id
        self.title = title
        self.languageCode = languageCode
        self.codec = codec
        self.channels = channels
        self.isSelected = isSelected
    }

    public var displayTitle: String {
        var pieces: [String] = []
        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedTitle.isEmpty {
            pieces.append(cleanedTitle)
        } else if let languageCode, !languageCode.isEmpty {
            pieces.append(languageCode.uppercased())
        } else {
            pieces.append("Audio")
        }
        if let codec, !codec.isEmpty {
            pieces.append(codec.uppercased())
        }
        if let channels {
            pieces.append("\(channels) ch")
        }
        return pieces.joined(separator: " - ")
    }

    public func withSelection(_ selected: Bool) -> MediaAudioTrack {
        MediaAudioTrack(
            id: id,
            title: title,
            languageCode: languageCode,
            codec: codec,
            channels: channels,
            isSelected: selected
        )
    }
}

public struct MediaSubtitleTrack: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let title: String
    public let languageCode: String?
    public let codec: String?
    /// Forced subtitles (signs/foreign dialogue only). Surfaced as a "Forced"
    /// suffix so the user can tell a forced track from a full one.
    public let isForced: Bool
    public let isSelected: Bool

    public init(
        id: String,
        title: String,
        languageCode: String? = nil,
        codec: String? = nil,
        isForced: Bool = false,
        isSelected: Bool = false
    ) {
        self.id = id
        self.title = title
        self.languageCode = languageCode
        self.codec = codec
        self.isForced = isForced
        self.isSelected = isSelected
    }

    public var displayTitle: String {
        var label: String
        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedTitle.isEmpty {
            label = cleanedTitle
        } else if let languageCode, !languageCode.isEmpty {
            label = languageCode.uppercased()
        } else {
            label = "Subtitle"
        }
        if isForced, !label.localizedCaseInsensitiveContains("forced") {
            label += " (Forced)"
        }
        return label
    }

    public func withSelection(_ selected: Bool) -> MediaSubtitleTrack {
        MediaSubtitleTrack(
            id: id,
            title: title,
            languageCode: languageCode,
            codec: codec,
            isForced: isForced,
            isSelected: selected
        )
    }
}

/// A cast or crew member for the Detail "Cast & Crew" rail — an actor with the
/// character they play, or key crew (director / writer) with their job. The
/// `photoURL` is a ready-to-load, server-resized headshot (tokenised on-device,
/// like the rest of the artwork) or `nil` when the source has no image.
public struct CastMember: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    /// The person's name, e.g. "Ryan Gosling".
    public let name: String
    /// The character they play ("Neil Armstrong") or, for crew, their job
    /// ("Director"). `nil` when the source didn't provide one.
    public let role: String?
    public let photoURL: URL?
    /// Source-scoped person id queryable via `items(withPerson:)` — Plex tag id /
    /// Jellyfin person GUID. Drives the tappable Cast → filmography (#341). `nil`
    /// when the source didn't supply one (the card stays non-interactive).
    public let personID: String?

    public init(id: String, name: String, role: String? = nil, photoURL: URL? = nil, personID: String? = nil) {
        self.id = id
        self.name = name
        self.role = role
        self.photoURL = photoURL
        self.personID = personID
    }
}

/// Identity of a media item, scoped by its source.
public struct MediaID: Hashable, Sendable {
    public let source: MediaSourceID
    public let rawValue: String

    public init(source: MediaSourceID, rawValue: String) {
        self.source = source
        self.rawValue = rawValue
    }

    /// A stable, run-to-run identical string identifying this item — its
    /// source's `stableKey` joined to the raw id. Suitable as a dictionary key
    /// when a `String` is needed instead of the `Hashable` value itself.
    public var key: String { "\(source.stableKey):\(rawValue)" }
}

/// Identifies which source (mock / Plex / Jellyfin / Emby server / SMB share /
/// DLNA server / on-device Local Library) an item came from.
public enum MediaSourceID: Hashable, Sendable {
    case mock
    case plex(serverID: String)
    case jellyfin(serverID: String)
    case emby(serverID: String)
    /// A configured SMB share, keyed by a stable record UUID (not host) so an
    /// IP/host change doesn't orphan resume state (#214).
    case smb(id: String)
    /// A DLNA/UPnP media server, keyed by its device UDN (`uuid:…`) — stable
    /// across the server's IP churn (#212).
    case dlna(udn: String)
    /// The on-device Local Library (files Aether owns). Singular — one store
    /// per device — so no associated value. See #173.
    case local
    /// An **availability-only** title that Aether doesn't host or stream — today
    /// a Netflix-only title from TMDb Watch Providers (#360). Never enters the
    /// unified playback priority (`MediaSourceKind(streaming:)` returns nil); its
    /// synthesized `MediaItem` has no `streamURL`, so Detail offers "Play on
    /// Netflix" (link-out) instead of in-app playback. Keyed by TMDb id so the
    /// same title is stable run-to-run.
    case external(id: String)

    /// A stable, run-to-run identical string for this source. Suitable as a
    /// component of persistence keys (e.g. per-library preferences). The
    /// default `String(describing:)` reflects the underlying Swift enum
    /// representation and is *not* stable across compiler versions, so we
    /// hand-roll one here.
    public var stableKey: String {
        switch self {
        case .mock:
            return "mock"
        case .plex(let serverID):
            return "plex.\(serverID)"
        case .jellyfin(let serverID):
            return "jellyfin.\(serverID)"
        case .emby(let serverID):
            return "emby.\(serverID)"
        case .smb(let id):
            return "smb.\(id)"
        case .dlna(let udn):
            return "dlna.\(udn)"
        case .local:
            return "local"
        case .external(let id):
            return "external.\(id)"
        }
    }
}
