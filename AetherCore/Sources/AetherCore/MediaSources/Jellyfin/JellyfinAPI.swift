import Foundation

/// DTO namespace for the Jellyfin HTTP API — the shapes Aether decodes. Mirrors
/// `PlexAPI`. Jellyfin uses PascalCase keys, so each type maps them via
/// `CodingKeys`.
public enum JellyfinAPI {

    // MARK: - Server validation

    /// `GET /System/Info/Public` — used to confirm a URL really points at a
    /// Jellyfin server before we try to sign in.
    public struct PublicSystemInfo: Decodable, Sendable, Equatable {
        public let id: String?
        public let serverName: String?
        public let version: String?
        public let productName: String?

        enum CodingKeys: String, CodingKey {
            case id = "Id"
            case serverName = "ServerName"
            case version = "Version"
            case productName = "ProductName"
        }
    }

    // MARK: - Quick Connect

    /// `GET /QuickConnect/Initiate` and `GET /QuickConnect/Connect` both return
    /// this shape; `authenticated` flips true once the user approves the code.
    public struct QuickConnectResult: Decodable, Sendable, Equatable {
        public let secret: String
        public let code: String
        public let authenticated: Bool

        enum CodingKeys: String, CodingKey {
            case secret = "Secret"
            case code = "Code"
            case authenticated = "Authenticated"
        }
    }

    /// `POST /Users/AuthenticateWithQuickConnect` → the access token + user.
    public struct AuthenticationResult: Decodable, Sendable, Equatable {
        public let accessToken: String
        public let serverID: String?
        public let user: User

        public struct User: Decodable, Sendable, Equatable {
            public let id: String
            public let name: String?

            enum CodingKeys: String, CodingKey {
                case id = "Id"
                case name = "Name"
            }
        }

        enum CodingKeys: String, CodingKey {
            case accessToken = "AccessToken"
            case serverID = "ServerId"
            case user = "User"
        }
    }

    // MARK: - Items

    /// `GET /Users/{id}/Items` and `/Users/{id}/Views` wrap items in this.
    public struct ItemsResponse: Decodable, Sendable {
        public let items: [BaseItemDto]
        public let totalRecordCount: Int?

        enum CodingKeys: String, CodingKey {
            case items = "Items"
            case totalRecordCount = "TotalRecordCount"
        }
    }

    // MARK: - Media segments (Skip Intro / Credits)

    /// `GET /MediaSegments/{itemId}` wraps segments in this (QueryResult shape).
    public struct MediaSegmentsResponse: Decodable, Sendable {
        public let items: [MediaSegmentDto]
        enum CodingKeys: String, CodingKey { case items = "Items" }
    }

    /// One Jellyfin MediaSegment. Times are 100-ns ticks. Types: Intro, Outro,
    /// Recap, Preview, Commercial (10.10+).
    public struct MediaSegmentDto: Decodable, Sendable, Equatable {
        public let type: String?
        public let startTicks: Int64?
        public let endTicks: Int64?

        enum CodingKeys: String, CodingKey {
            case type = "Type"
            case startTicks = "StartTicks"
            case endTicks = "EndTicks"
        }

        /// Mapped to a source-agnostic `PlaybackSegment`, or `nil` if the type
        /// isn't one we surface or the ticks are missing.
        public var segment: PlaybackSegment? {
            guard let startTicks, let endTicks, let kind = Self.kind(for: type) else { return nil }
            return PlaybackSegment(
                kind: kind,
                start: Double(startTicks) / 10_000_000,
                end: Double(endTicks) / 10_000_000
            )
        }

        static func kind(for type: String?) -> PlaybackSegment.Kind? {
            switch type?.lowercased() {
            case "intro":      return .intro
            case "outro":      return .credits
            case "recap":      return .recap
            case "preview":    return .preview
            case "commercial": return .commercial
            default:           return nil
            }
        }
    }

    public struct BaseItemDto: Decodable, Sendable, Equatable {
        public let id: String
        public let name: String?
        public let type: String?            // "Movie", "Series", "Season", "Episode"
        public let collectionType: String?  // on views: "movies", "tvshows"
        public let overview: String?
        public let productionYear: Int?
        public let runTimeTicks: Int64?     // 100-ns ticks
        public let imageTags: [String: String]?
        public let backdropImageTags: [String]?
        public let mediaSources: [MediaSourceInfo]?
        /// For episodes: the parent season's id (`ParentId`) — Auto-Play-Next
        /// fetches the season's episodes from it.
        public let parentId: String?
        /// External-ID map, e.g. `{"Tmdb":"12345","Imdb":"tt0083658"}`. Basis
        /// for Unified Library dedup.
        public let providerIds: [String: String]?
        /// Per-user playback state. `Played == true` ⇒ watched. Jellyfin returns
        /// it on the user-scoped `/Users/{id}/Items` endpoint.
        public let userData: UserData?
        /// For a Series: number of seasons (`ChildCount`).
        public let childCount: Int?
        /// For a Series: total number of episodes (`RecursiveItemCount`).
        public let recursiveItemCount: Int?
        /// When the item was added to the library (`DateCreated`, ISO-8601).
        public let dateCreated: String?
        /// Original release / air date (`PremiereDate`, ISO-8601).
        public let premiereDate: String?
        /// For a Series: date the show ended (`EndDate`, ISO-8601). Absent while
        /// the show is still airing.
        public let endDate: String?
        /// Critic/community score on a 0–10 scale (`CommunityRating`).
        public let communityRating: Double?
        /// Genre names (`Genres`).
        public let genres: [String]?
        /// For a Series: airing status (`Status`, e.g. "Continuing", "Ended").
        public let status: String?
        /// For a season or episode: its own number (`IndexNumber`).
        public let indexNumber: Int?
        /// For an episode: its season's number (`ParentIndexNumber`).
        public let parentIndexNumber: Int?
        /// For an episode: the series title (`SeriesName`).
        public let seriesName: String?
        /// Age / content classification (`OfficialRating`), e.g. "PG-13",
        /// "TV-MA", "15". Rendered as a badge in the Detail metadata line.
        public let officialRating: String?

        public struct UserData: Decodable, Sendable, Equatable {
            public let played: Bool?
            /// For a season / series: how many episodes are still unplayed
            /// (`UnplayedItemCount`). Drives Series Detail's On Deck.
            public let unplayedItemCount: Int?
            public init(played: Bool? = nil, unplayedItemCount: Int? = nil) {
                self.played = played
                self.unplayedItemCount = unplayedItemCount
            }
            enum CodingKeys: String, CodingKey {
                case played = "Played"
                case unplayedItemCount = "UnplayedItemCount"
            }
        }

        /// External IDs as a typed `MediaGuids` (case-insensitive provider keys).
        public var guids: MediaGuids {
            guard let ids = providerIds else { return MediaGuids() }
            func value(_ provider: String) -> String? {
                ids.first { $0.key.caseInsensitiveCompare(provider) == .orderedSame }?.value
            }
            return MediaGuids(tmdb: value("Tmdb"), imdb: value("Imdb"), tvdb: value("Tvdb"))
        }

        /// Whether the user has watched this item, per Jellyfin's play state.
        public var isWatched: Bool { userData?.played ?? false }

        /// Genres as a non-optional list.
        public var genreList: [String] { genres ?? [] }

        /// Original release date parsed from `PremiereDate`.
        public var releaseDate: Date? { Self.parseDate(premiereDate) }

        /// Date the item was added to the library, parsed from `DateCreated`.
        public var dateAdded: Date? { Self.parseDate(dateCreated) }

        /// For an ended series, the final airing year (from `EndDate`). `nil`
        /// while the show is still continuing, which the UI renders as "Present".
        public var endYear: Int? {
            guard status != "Continuing", let endDate, endDate.count >= 4 else { return nil }
            return Int(endDate.prefix(4))
        }

        /// Parse a Jellyfin ISO-8601 timestamp (may carry up to 7 fractional
        /// digits), tolerating the presence or absence of fractional seconds.
        static func parseDate(_ raw: String?) -> Date? {
            guard let raw, !raw.isEmpty else { return nil }
            var withFractional: ISO8601DateFormatter.Options = .withInternetDateTime
            withFractional.insert(.withFractionalSeconds)
            for options: ISO8601DateFormatter.Options in [withFractional, .withInternetDateTime] {
                let f = ISO8601DateFormatter()
                f.formatOptions = options
                if let date = f.date(from: raw) { return date }
            }
            return nil
        }

        public var kind: MediaItem.Kind? {
            switch type {
            case "Movie":   return .movie
            case "Episode": return .episode
            case "Series":  return .show
            case "Season":  return .season
            default:        return nil
            }
        }

        /// The first media source's container (e.g. "mp4", "mkv"), used to
        /// decide direct-play vs transcode.
        public var container: String? {
            mediaSources?.first?.container
        }

        public var mediaSourceID: String? {
            mediaSources?.first?.id
        }

        /// Content rating cleaned of blank server strings.
        public var contentRating: String? { officialRating?.nonEmptyTrimmed }

        private var firstStreams: [MediaStream] {
            mediaSources?.first?.mediaStreams ?? []
        }

        /// Codec / resolution / channels / HDR / bitrate / file size for the
        /// Detail screen — mapped from the first media source's video + audio
        /// streams. Backfills the `MediaInfo` Jellyfin previously left `nil`,
        /// so codec badges + Technical Details work for Jellyfin as they do
        /// for Plex. Returns `nil` when there's no media source at all.
        public var sourceMediaInfo: MediaInfo? {
            guard let source = mediaSources?.first else { return nil }
            let streams = source.mediaStreams ?? []
            let video = streams.first { $0.type == "Video" }
            let audio = streams.first { $0.type == "Audio" && ($0.isDefault ?? false) }
                ?? streams.first { $0.type == "Audio" }
            // Stream bitrate is bits/s; MediaInfo wants kbps. Prefer the video
            // stream's own rate, fall back to the source-level bitrate.
            let bitsPerSecond = video?.bitRate ?? source.bitrate
            let kbps = bitsPerSecond.map { $0 / 1000 }
            return MediaInfo(
                videoCodec: video?.codec?.nonEmptyTrimmed,
                audioCodec: audio?.codec?.nonEmptyTrimmed,
                audioChannels: audio?.channels,
                videoResolution: video?.resolutionLabel,
                bitrateKbps: kbps,
                isHDR: video?.isHDR ?? false,
                isDolbyVision: video?.isDolbyVision ?? false,
                container: source.container?.nonEmptyTrimmed,
                fileSizeBytes: source.size
            )
        }

        public var audioTracks: [MediaAudioTrack] {
            firstStreams.enumerated().compactMap { _, stream in
                guard stream.type == "Audio" else { return nil }
                return MediaAudioTrack(
                    id: String(stream.index),
                    title: stream.bestTitle,
                    languageCode: stream.language,
                    codec: stream.codec,
                    channels: stream.channels,
                    isSelected: stream.isDefault ?? false
                )
            }
        }

        public var subtitleTracks: [MediaSubtitleTrack] {
            firstStreams.compactMap { stream in
                guard stream.type == "Subtitle" else { return nil }
                return MediaSubtitleTrack(
                    id: String(stream.index),
                    title: stream.bestTitle,
                    languageCode: stream.language,
                    codec: stream.codec,
                    isForced: stream.isForced ?? false,
                    isSelected: stream.isDefault ?? false
                )
            }
        }

        enum CodingKeys: String, CodingKey {
            case id = "Id"
            case name = "Name"
            case type = "Type"
            case collectionType = "CollectionType"
            case overview = "Overview"
            case productionYear = "ProductionYear"
            case runTimeTicks = "RunTimeTicks"
            case imageTags = "ImageTags"
            case backdropImageTags = "BackdropImageTags"
            case mediaSources = "MediaSources"
            case parentId = "ParentId"
            case providerIds = "ProviderIds"
            case userData = "UserData"
            case childCount = "ChildCount"
            case recursiveItemCount = "RecursiveItemCount"
            case dateCreated = "DateCreated"
            case premiereDate = "PremiereDate"
            case endDate = "EndDate"
            case communityRating = "CommunityRating"
            case genres = "Genres"
            case status = "Status"
            case indexNumber = "IndexNumber"
            case parentIndexNumber = "ParentIndexNumber"
            case seriesName = "SeriesName"
            case officialRating = "OfficialRating"
        }
    }

    public struct MediaSourceInfo: Decodable, Sendable, Equatable {
        public let id: String?
        public let container: String?
        public let mediaStreams: [MediaStream]?
        /// Source file size in **bytes** (`Size`). `nil` when not reported.
        public let size: Int64?
        /// Overall source bitrate in **bits per second** (`Bitrate`). Used as a
        /// fallback when the video stream itself doesn't carry a bitrate.
        public let bitrate: Int?

        enum CodingKeys: String, CodingKey {
            case id = "Id"
            case container = "Container"
            case mediaStreams = "MediaStreams"
            case size = "Size"
            case bitrate = "Bitrate"
        }
    }

    public struct MediaStream: Decodable, Sendable, Equatable {
        public let index: Int
        public let type: String             // "Audio", "Subtitle", "Video"
        public let displayTitle: String?
        public let language: String?
        public let codec: String?
        public let channels: Int?
        public let isDefault: Bool?
        public let isForced: Bool?
        /// Video stream pixel width / height (`Width` / `Height`). Used to label
        /// the resolution ("4K", "1080p") when present on the video stream.
        public let width: Int?
        public let height: Int?
        /// `VideoRange` is "SDR" / "HDR"; `VideoRangeType` is finer-grained
        /// ("HDR10", "HLG", "DOVI", "DOVIWithHDR10"). Together they drive the
        /// HDR / Dolby-Vision badges.
        public let videoRange: String?
        public let videoRangeType: String?
        /// Per-stream bitrate in **bits per second** (`BitRate`).
        public let bitRate: Int?

        public var bestTitle: String {
            [displayTitle, language]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "Track \(index)"
        }

        /// True when this video stream carries HDR (HDR10 / HLG / Dolby Vision).
        public var isHDR: Bool {
            if videoRange?.localizedCaseInsensitiveContains("hdr") == true { return true }
            if let t = videoRangeType?.lowercased() {
                return t.contains("hdr") || t.contains("hlg") || t.contains("dovi")
            }
            return false
        }

        /// True when this video stream is tagged Dolby Vision.
        public var isDolbyVision: Bool {
            videoRangeType?.localizedCaseInsensitiveContains("dovi") == true
        }

        /// Resolution label ("4K", "1080p", "720p") derived from `width`/`height`.
        public var resolutionLabel: String? {
            guard let height else { return nil }
            switch height {
            case 1601...:   return "4K"
            case 1081...1600: return "1440p"
            case 721...1080:  return "1080p"
            case 577...720:   return "720p"
            case 1...576:     return "480p"
            default:          return nil
            }
        }

        enum CodingKeys: String, CodingKey {
            case index = "Index"
            case type = "Type"
            case displayTitle = "DisplayTitle"
            case language = "Language"
            case codec = "Codec"
            case channels = "Channels"
            case isDefault = "IsDefault"
            case isForced = "IsForced"
            case width = "Width"
            case height = "Height"
            case videoRange = "VideoRange"
            case videoRangeType = "VideoRangeType"
            case bitRate = "BitRate"
        }
    }
}
