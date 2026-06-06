import Foundation

/// Namespace for `Decodable` shapes returned by plex.tv and PMS endpoints.
///
/// Kept under one type so call sites read clearly (`PlexAPI.PIN`, `PlexAPI.Resource`)
/// and so we don't pollute the top-level AetherCore namespace with Plex-only types.
public enum PlexAPI {

    /// Parses Plex's `originallyAvailableAt` ("YYYY-MM-DD", UTC).
    static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Response from `POST /api/v2/pins` and `GET /api/v2/pins/{id}`.
    ///
    /// `authToken` is `nil` until the user enters the displayed `code` at
    /// plex.tv/link; after that it becomes the per-user token used for all
    /// subsequent plex.tv calls.
    public struct PIN: Decodable, Sendable, Equatable {
        public let id: Int
        public let code: String
        public let authToken: String?
        public let expiresAt: Date?

        public init(id: Int, code: String, authToken: String?, expiresAt: Date?) {
            self.id = id
            self.code = code
            self.authToken = authToken
            self.expiresAt = expiresAt
        }
    }

    /// One entry from `GET /api/v2/resources`. Plex returns these as a JSON
    /// array; each describes a server (or device) the user has access to.
    public struct Resource: Decodable, Sendable, Equatable {
        public let name: String
        public let product: String
        public let clientIdentifier: String
        public let provides: String
        public let owned: Bool
        public let accessToken: String?
        public let connections: [Connection]

        public var providesServer: Bool {
            provides
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .contains("server")
        }

        public struct Connection: Decodable, Sendable, Equatable {
            public let uri: String
            public let address: String
            public let port: Int
            public let local: Bool
            public let relay: Bool

            /// PMS connections always carry the protocol explicitly because the
            /// same address can be reachable on http and https.
            public let connectionProtocol: String

            enum CodingKeys: String, CodingKey {
                case uri, address, port, local, relay
                case connectionProtocol = "protocol"
            }
        }
    }

    // MARK: - Library shapes (PMS-side, returned by /library/...)

    /// Response wrapper for any PMS endpoint — Plex wraps every payload in
    /// `{ "MediaContainer": { ... } }`. We only model the keys we read.
    public struct LibrarySectionsResponse: Decodable, Sendable {
        public let mediaContainer: Container

        public struct Container: Decodable, Sendable {
            /// Plex omits `Directory` entirely when there are no libraries.
            public let directory: [LibrarySection]?

            enum CodingKeys: String, CodingKey {
                case directory = "Directory"
            }
        }

        enum CodingKeys: String, CodingKey {
            case mediaContainer = "MediaContainer"
        }
    }

    /// One library section as returned by `GET /library/sections`.
    public struct LibrarySection: Decodable, Sendable, Equatable {
        public let key: String
        public let title: String
        /// `"movie"`, `"show"`, `"artist"`, `"photo"`, …
        public let type: String

        public var kind: MediaItem.Kind? {
            switch type {
            case "movie": return .movie
            case "show":  return .show
            default:      return nil   // unsupported in 0.2 (music, photos)
            }
        }
    }

    // MARK: - Decision endpoint

    /// Response wrapper for `GET /video/:/transcode/universal/decision`.
    ///
    /// Plex returns the same `MediaContainer.Metadata` shape it uses for
    /// library listings, plus a few decision-level fields at the container.
    /// We model only what the playback pipeline reads.
    public struct DecisionResponse: Decodable, Sendable {
        public let mediaContainer: Container

        public struct Container: Decodable, Sendable {
            public let generalDecisionCode: Int?
            public let generalDecisionText: String?
            public let mdeDecisionCode: Int?
            public let transcodeDecisionCode: Int?
            public let directPlayDecisionCode: Int?
            public let directPlayDecisionText: String?
            public let metadata: [DecisionMetadata]?

            enum CodingKeys: String, CodingKey {
                case generalDecisionCode, generalDecisionText
                case mdeDecisionCode, transcodeDecisionCode
                case directPlayDecisionCode, directPlayDecisionText
                case metadata = "Metadata"
            }
        }

        enum CodingKeys: String, CodingKey {
            case mediaContainer = "MediaContainer"
        }
    }

    /// One metadata entry from a decision response — same shape as a library
    /// `Metadata` but with `Part.decision` populated and the chosen Part's
    /// `file` path for direct-play URL construction.
    public struct DecisionMetadata: Decodable, Sendable {
        public let media: [DecisionMedia]?

        enum CodingKeys: String, CodingKey {
            case media = "Media"
        }

        public struct DecisionMedia: Decodable, Sendable {
            public let videoCodec: String?
            public let audioCodec: String?
            public let videoResolution: String?
            public let bitrate: Int?
            public let container: String?
            public let part: [DecisionPart]?

            enum CodingKeys: String, CodingKey {
                case videoCodec, audioCodec, videoResolution, bitrate, container
                case part = "Part"
            }
        }

        public struct DecisionPart: Decodable, Sendable {
            /// One of `"directplay"`, `"copy"` (direct stream), `"transcode"`.
            /// Plex names this verdict on the Part itself; we map it into
            /// `PlaybackDecisionMode`.
            public let decision: String?
            /// Filesystem path to the original file, e.g.
            /// `/data/Tron Ares.mkv`. Surfaced from the decision response so we
            /// can build the direct-play URL (`/library/parts/{partId}/{ts}/{name}`
            /// is encoded by Plex into `key` on the regular Part; the decision
            /// response duplicates it as `file`).
            public let file: String?
            /// Same `key` Plex returns on library Parts — relative URL Path the
            /// client can fetch directly.
            public let key: String?

            enum CodingKeys: String, CodingKey {
                case decision, file, key
            }
        }
    }

    /// Response wrapper for `GET /library/sections/{key}/all`.
    public struct LibraryItemsResponse: Decodable, Sendable {
        public let mediaContainer: Container

        public struct Container: Decodable, Sendable {
            public let metadata: [Metadata]?

            enum CodingKeys: String, CodingKey {
                case metadata = "Metadata"
            }
        }

        enum CodingKeys: String, CodingKey {
            case mediaContainer = "MediaContainer"
        }
    }

    /// One metadata item — a movie, show, episode, season, album, etc.
    /// We only model the fields the player needs in 0.2.
    public struct Metadata: Decodable, Sendable, Equatable {
        public let ratingKey: String
        public let type: String           // "movie", "show", "episode", "season", …
        public let title: String
        public let summary: String?
        public let year: Int?
        /// Runtime in **milliseconds** — Plex's wire convention.
        public let duration: Int?
        /// Relative path to the poster — needs the server base URL and a token.
        public let thumb: String?
        /// Relative path to the backdrop / art.
        public let art: String?
        /// For episodes: the parent series's title (Plex sends it as
        /// `grandparentTitle`). `nil` for movies / shows / seasons.
        public let grandparentTitle: String?
        /// For episodes: the parent season's number (Plex's `parentIndex`).
        /// Combined with `index` to render "S1E1" in UI.
        public let parentIndex: Int?
        /// For episodes: the parent season's ratingKey — the id Auto-Play-Next
        /// fetches the season's episodes from. JSON key `parentRatingKey`.
        public let parentRatingKey: String?
        /// For episodes: this episode's number within its season (Plex's
        /// `index`). Also doubles as season number on a season DTO, but
        /// we only read it from episodes today.
        public let index: Int?
        /// Playable media. Present on movies + episodes; absent on containers
        /// like shows and seasons (you play their children, not them).
        public let media: [Media]?

        /// External-ID tags Plex attaches per item, e.g. `tmdb://12345`,
        /// `imdb://tt0083658`, `tvdb://78874`. The basis for Unified Library
        /// dedup. JSON key is capital `Guid`; see `CodingKeys`.
        public let externalGuids: [GuidEntry]?
        /// Number of times the user has played this item. `>= 1` ⇒ watched.
        /// Plex includes it on list + detail by default. JSON key `viewCount`.
        public let viewCount: Int?
        /// Intro / credits / commercial markers — only returned on the detail
        /// endpoint with `includeMarkers=1`. JSON key capital `Marker`.
        public let markers: [MarkerEntry]?
        /// For shows: number of seasons (`childCount`) and total episodes
        /// (`leafCount`).
        public let childCount: Int?
        public let leafCount: Int?
        /// For a season / show: episodes already watched (`viewedLeafCount`).
        /// Combined with `leafCount` to know how many remain — On Deck.
        public let viewedLeafCount: Int?
        /// Epoch seconds the item was added to the library.
        public let addedAt: Int?
        /// Original release date, "YYYY-MM-DD".
        public let originallyAvailableAt: String?
        /// Audience / critic rating (0–10).
        public let audienceRating: Double?
        public let rating: Double?
        /// Genre tags (`{"tag": "Sci-Fi"}`). JSON key capital `Genre`.
        public let genreTags: [Tag]?

        public struct Tag: Decodable, Sendable, Equatable {
            public let tag: String?
            public init(tag: String? = nil) { self.tag = tag }
        }

        public struct GuidEntry: Decodable, Sendable, Equatable {
            public let id: String
            public init(id: String) { self.id = id }
        }

        /// One Plex marker. `startTimeOffset` / `endTimeOffset` are **milliseconds**.
        public struct MarkerEntry: Decodable, Sendable, Equatable {
            public let type: String?
            public let startTimeOffset: Int?
            public let endTimeOffset: Int?

            public init(type: String? = nil, startTimeOffset: Int? = nil, endTimeOffset: Int? = nil) {
                self.type = type
                self.startTimeOffset = startTimeOffset
                self.endTimeOffset = endTimeOffset
            }

            public var segment: PlaybackSegment? {
                guard let startTimeOffset, let endTimeOffset, let kind = Self.kind(for: type) else { return nil }
                return PlaybackSegment(
                    kind: kind,
                    start: Double(startTimeOffset) / 1000,
                    end: Double(endTimeOffset) / 1000
                )
            }

            static func kind(for type: String?) -> PlaybackSegment.Kind? {
                switch type?.lowercased() {
                case "intro":              return .intro
                case "credits", "credit":  return .credits
                case "commercial":         return .commercial
                default:                   return nil
                }
            }
        }

        /// External IDs parsed into a typed `MediaGuids`.
        public var guids: MediaGuids {
            MediaGuids(guidStrings: (externalGuids ?? []).map(\.id))
        }

        /// Markers mapped to source-agnostic `PlaybackSegment`s.
        public var segments: [PlaybackSegment] {
            (markers ?? []).compactMap(\.segment)
        }

        /// Genre tag strings.
        public var genres: [String] {
            (genreTags ?? []).compactMap(\.tag)
        }

        /// Library-add date from `addedAt` epoch seconds.
        public var dateAdded: Date? {
            addedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        }

        /// Release date parsed from `originallyAvailableAt` ("YYYY-MM-DD").
        public var releaseDate: Date? {
            guard let value = originallyAvailableAt else { return nil }
            return PlexAPI.dateOnlyFormatter.date(from: value)
        }

        /// Unwatched episodes for a season / show: `leafCount − viewedLeafCount`.
        /// `nil` unless both counts are present.
        public var unwatchedLeafCount: Int? {
            guard let leafCount else { return nil }
            return max(0, leafCount - (viewedLeafCount ?? 0))
        }

        /// Explicit init with defaults for every optional field, so the
        /// test fixtures that build `Metadata` synthetically don't have
        /// to enumerate the full optional tail each time a new field
        /// lands (e.g. episode context). New episode fields default to
        /// `nil` so existing test call sites compile unchanged.
        public init(
            ratingKey: String,
            type: String,
            title: String,
            summary: String? = nil,
            year: Int? = nil,
            duration: Int? = nil,
            thumb: String? = nil,
            art: String? = nil,
            grandparentTitle: String? = nil,
            parentIndex: Int? = nil,
            parentRatingKey: String? = nil,
            index: Int? = nil,
            media: [Media]? = nil,
            externalGuids: [GuidEntry]? = nil,
            viewCount: Int? = nil,
            markers: [MarkerEntry]? = nil,
            childCount: Int? = nil,
            leafCount: Int? = nil,
            viewedLeafCount: Int? = nil,
            addedAt: Int? = nil,
            originallyAvailableAt: String? = nil,
            audienceRating: Double? = nil,
            rating: Double? = nil,
            genreTags: [Tag]? = nil
        ) {
            self.ratingKey = ratingKey
            self.type = type
            self.title = title
            self.summary = summary
            self.year = year
            self.duration = duration
            self.thumb = thumb
            self.art = art
            self.grandparentTitle = grandparentTitle
            self.parentIndex = parentIndex
            self.parentRatingKey = parentRatingKey
            self.index = index
            self.media = media
            self.externalGuids = externalGuids
            self.viewCount = viewCount
            self.markers = markers
            self.childCount = childCount
            self.leafCount = leafCount
            self.viewedLeafCount = viewedLeafCount
            self.addedAt = addedAt
            self.originallyAvailableAt = originallyAvailableAt
            self.audienceRating = audienceRating
            self.rating = rating
            self.genreTags = genreTags
        }

        public var kind: MediaItem.Kind {
            switch type {
            case "movie":   return .movie
            case "episode": return .episode
            case "show":    return .show
            case "season":  return .season
            default:        return .movie  // best-effort fallback
            }
        }

        /// The first part's relative `key` — the direct-play file path.
        /// `/library/sections/{key}/all` includes Media + Part inline for
        /// movies and episodes, so no extra request is needed to resolve it.
        public var firstPartKey: String? {
            media?.first?.part?.first?.key
        }

        /// The first media's container (e.g. `"mp4"`, `"mkv"`). Used to decide
        /// whether AVPlayer can direct-play the file or whether we route it
        /// through the server's transcoder.
        public var firstContainer: String? {
            media?.first?.container
        }

        public var audioTracks: [MediaAudioTrack] {
            guard let streams = media?.first?.part?.first?.stream else { return [] }
            return streams.enumerated().compactMap { index, stream in
                guard stream.streamType == 2, let id = stream.id else { return nil }
                let fallbackTitle = "Audio \(index + 1)"
                return MediaAudioTrack(
                    id: id,
                    title: stream.bestTitle ?? fallbackTitle,
                    languageCode: stream.languageCode,
                    codec: stream.codec,
                    channels: stream.channels,
                    isSelected: stream.selected ?? false
                )
            }
        }

        public var selectedAudioTrackID: String? {
            audioTracks.first(where: \.isSelected)?.id
        }

        /// Subtitle streams (`streamType == 3`) from the first media part —
        /// the same `Stream` list audio tracks come from. Forced status is
        /// inferred from the title (Plex doesn't always set an explicit flag
        /// in this response shape), e.g. "Czech (Forced)".
        public var subtitleTracks: [MediaSubtitleTrack] {
            guard let streams = media?.first?.part?.first?.stream else { return [] }
            return streams.enumerated().compactMap { index, stream in
                guard stream.streamType == 3, let id = stream.id else { return nil }
                let fallbackTitle = "Subtitle \(index + 1)"
                let title = stream.bestTitle ?? fallbackTitle
                return MediaSubtitleTrack(
                    id: id,
                    title: title,
                    languageCode: stream.languageCode,
                    codec: stream.codec,
                    isForced: title.localizedCaseInsensitiveContains("forced"),
                    isSelected: stream.selected ?? false
                )
            }
        }

        public var selectedSubtitleTrackID: String? {
            subtitleTracks.first(where: \.isSelected)?.id
        }

        /// The first Part's id surfaced as a string. Drives the
        /// `PUT /library/parts/{partId}` stream-selection step.
        public var firstPartID: String? {
            media?.first?.part?.first?.id
        }

        /// Source media info for Detail-screen display: codec, resolution,
        /// channels, HDR flags, source bitrate. Pulled from the first Media +
        /// its primary video/audio streams.
        public var sourceMediaInfo: MediaInfo? {
            guard let media = media?.first else { return nil }
            let part = media.part?.first
            let video = part?.stream?.first { $0.streamType == 1 }
            let audio = part?.stream?.first { $0.streamType == 2 && ($0.selected ?? false) }
                ?? part?.stream?.first { $0.streamType == 2 }
            let resolutionLabel: String? = {
                if let r = media.videoResolution, !r.isEmpty {
                    return Self.resolutionLabel(from: r)
                }
                return nil
            }()
            return MediaInfo(
                videoCodec: media.videoCodec ?? video?.codec,
                audioCodec: media.audioCodec ?? audio?.codec,
                audioChannels: audio?.channels ?? media.audioChannels,
                videoResolution: resolutionLabel,
                bitrateKbps: media.bitrate,
                isHDR: video?.colorTrc?.localizedCaseInsensitiveContains("smpte2084") == true
                    || video?.colorTrc?.localizedCaseInsensitiveContains("hlg") == true
                    || video?.dovi == true,
                isDolbyVision: video?.dovi == true,
                container: media.container
            )
        }

        /// Translate Plex's free-form resolution value (`"1080"`, `"720"`,
        /// `"4k"`) into the label we show on Detail.
        private static func resolutionLabel(from raw: String) -> String {
            switch raw.lowercased() {
            case "4k", "2160": return "4K"
            case "1080":       return "1080p"
            case "720":        return "720p"
            case "480":        return "480p"
            default:           return raw
            }
        }

        enum CodingKeys: String, CodingKey {
            case ratingKey, type, title, summary, year, duration, thumb, art
            case grandparentTitle, parentIndex, parentRatingKey, index, viewCount
            case childCount, leafCount, viewedLeafCount, addedAt, originallyAvailableAt, audienceRating, rating
            case media = "Media"
            case externalGuids = "Guid"
            case markers = "Marker"
            case genreTags = "Genre"
        }

        public struct Media: Decodable, Sendable, Equatable {
            /// File container, e.g. `"mp4"`, `"mkv"`, `"avi"`.
            public let container: String?
            public let videoCodec: String?
            public let audioCodec: String?
            /// Source bitrate in **kilobits per second**.
            public let bitrate: Int?
            /// Plex's free-form resolution label (`"1080"`, `"4k"`).
            public let videoResolution: String?
            public let audioChannels: Int?
            public let part: [Part]?

            public init(
                container: String? = nil,
                videoCodec: String? = nil,
                audioCodec: String? = nil,
                bitrate: Int? = nil,
                videoResolution: String? = nil,
                audioChannels: Int? = nil,
                part: [Part]? = nil
            ) {
                self.container = container
                self.videoCodec = videoCodec
                self.audioCodec = audioCodec
                self.bitrate = bitrate
                self.videoResolution = videoResolution
                self.audioChannels = audioChannels
                self.part = part
            }

            enum CodingKeys: String, CodingKey {
                case container, videoCodec, audioCodec, bitrate, videoResolution, audioChannels
                case part = "Part"
            }
        }

        public struct Part: Decodable, Sendable, Equatable {
            /// Plex Part id (e.g. `"17905"`). Surfaced as a String to match
            /// stream id encoding; Plex returns it as int or string depending
            /// on endpoint shape, so the custom decoder handles both.
            public let id: String?
            /// Relative path to the original file, e.g.
            /// `/library/parts/12345/1700000000/file.mkv`.
            public let key: String?
            public let stream: [Stream]?

            public init(id: String? = nil, key: String?, stream: [Stream]? = nil) {
                self.id = id
                self.key = key
                self.stream = stream
            }

            enum CodingKeys: String, CodingKey {
                case id, key
                case stream = "Stream"
            }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if let int = try? container.decodeIfPresent(Int.self, forKey: .id) {
                    id = String(int)
                } else if let s = try? container.decodeIfPresent(String.self, forKey: .id) {
                    id = s
                } else {
                    id = nil
                }
                key = try container.decodeIfPresent(String.self, forKey: .key)
                stream = try container.decodeIfPresent([Stream].self, forKey: .stream)
            }

            public struct Stream: Decodable, Sendable, Equatable {
                public let id: String?
                public let streamType: Int?
                public let selected: Bool?
                public let codec: String?
                public let language: String?
                public let languageCode: String?
                public let title: String?
                public let channels: Int?
                /// Video color transfer (e.g. `"smpte2084"` for HDR10,
                /// `"arib-std-b67"` for HLG). Only present on video streams.
                public let colorTrc: String?
                /// `true` when Plex tagged the stream as Dolby Vision.
                public let dovi: Bool?

                public var bestTitle: String? {
                    [title, language, languageCode]
                        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .first { !$0.isEmpty }
                }

                public init(
                    id: String?,
                    streamType: Int?,
                    selected: Bool? = nil,
                    codec: String? = nil,
                    language: String? = nil,
                    languageCode: String? = nil,
                    title: String? = nil,
                    channels: Int? = nil,
                    colorTrc: String? = nil,
                    dovi: Bool? = nil
                ) {
                    self.id = id
                    self.streamType = streamType
                    self.selected = selected
                    self.codec = codec
                    self.language = language
                    self.languageCode = languageCode
                    self.title = title
                    self.channels = channels
                    self.colorTrc = colorTrc
                    self.dovi = dovi
                }

                enum CodingKeys: String, CodingKey {
                    case id, streamType, selected, codec, language, languageCode, title, channels, colorTrc, DOVIPresent
                }

                public init(from decoder: any Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    id = Self.decodeString(container, forKey: .id)
                    streamType = Self.decodeInt(container, forKey: .streamType)
                    selected = Self.decodeBool(container, forKey: .selected)
                    codec = try container.decodeIfPresent(String.self, forKey: .codec)
                    language = try container.decodeIfPresent(String.self, forKey: .language)
                    languageCode = try container.decodeIfPresent(String.self, forKey: .languageCode)
                    title = try container.decodeIfPresent(String.self, forKey: .title)
                    channels = Self.decodeInt(container, forKey: .channels)
                    colorTrc = try container.decodeIfPresent(String.self, forKey: .colorTrc)
                    dovi = Self.decodeBool(container, forKey: .DOVIPresent)
                }

                private static func decodeString(
                    _ container: KeyedDecodingContainer<CodingKeys>,
                    forKey key: CodingKeys
                ) -> String? {
                    if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                        return value
                    }
                    if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                        return String(value)
                    }
                    return nil
                }

                private static func decodeInt(
                    _ container: KeyedDecodingContainer<CodingKeys>,
                    forKey key: CodingKeys
                ) -> Int? {
                    if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                        return value
                    }
                    if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                        return Int(value)
                    }
                    return nil
                }

                private static func decodeBool(
                    _ container: KeyedDecodingContainer<CodingKeys>,
                    forKey key: CodingKeys
                ) -> Bool? {
                    if let value = try? container.decodeIfPresent(Bool.self, forKey: key) {
                        return value
                    }
                    if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                        return value != 0
                    }
                    if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                        switch value.lowercased() {
                        case "1", "true", "yes":
                            return true
                        case "0", "false", "no":
                            return false
                        default:
                            return nil
                        }
                    }
                    return nil
                }
            }
        }
    }
}
