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

        public struct UserData: Decodable, Sendable, Equatable {
            public let played: Bool?
            public init(played: Bool? = nil) { self.played = played }
            enum CodingKeys: String, CodingKey { case played = "Played" }
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

        private var firstStreams: [MediaStream] {
            mediaSources?.first?.mediaStreams ?? []
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
        }
    }

    public struct MediaSourceInfo: Decodable, Sendable, Equatable {
        public let id: String?
        public let container: String?
        public let mediaStreams: [MediaStream]?

        enum CodingKeys: String, CodingKey {
            case id = "Id"
            case container = "Container"
            case mediaStreams = "MediaStreams"
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

        public var bestTitle: String {
            [displayTitle, language]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "Track \(index)"
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
        }
    }
}
