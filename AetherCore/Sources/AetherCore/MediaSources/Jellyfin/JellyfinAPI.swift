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
