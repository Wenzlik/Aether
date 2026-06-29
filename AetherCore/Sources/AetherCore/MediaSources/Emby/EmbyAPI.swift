import Foundation

/// Emby REST API DTOs.
///
/// Emby and Jellyfin share a common ancestor, so the API surface is nearly
/// identical. Key differences from Jellyfin:
/// - No MediaSegments endpoint (skip intros are not supported server-side).
/// - `PublicSystemInfo` returns `ServerName` (same field, same path).
/// - Quick Connect flow is identical: `/QuickConnect/Enabled`,
///   `/QuickConnect/Initiate`, `/QuickConnect/Connect`, and
///   `/Users/AuthenticateWithQuickConnect`.
/// - Authorization header: same `MediaBrowser` format.
public enum EmbyAPI {

    // MARK: - System

    public struct PublicSystemInfo: Decodable, Sendable {
        public let serverName: String?
        public let version: String?

        private enum CodingKeys: String, CodingKey {
            case serverName = "ServerName"
            case version = "Version"
        }
    }

    // MARK: - Quick Connect

    public struct QuickConnectResult: Decodable, Sendable {
        /// The short code shown to the user.
        public let code: String
        /// The secret used to poll and authenticate.
        public let secret: String
        /// `true` once the user approves the code in the Emby dashboard.
        public let authenticated: Bool

        private enum CodingKeys: String, CodingKey {
            case code = "Code"
            case secret = "Secret"
            case authenticated = "Authenticated"
        }
    }

    public struct AuthenticationResult: Decodable, Sendable {
        public let accessToken: String
        public let user: UserDto

        private enum CodingKeys: String, CodingKey {
            case accessToken = "AccessToken"
            case user = "User"
        }

        public struct UserDto: Decodable, Sendable {
            public let id: String

            private enum CodingKeys: String, CodingKey {
                case id = "Id"
            }
        }
    }

    // MARK: - Items

    public struct ItemsResponse: Decodable, Sendable {
        public let items: [BaseItemDto]

        private enum CodingKeys: String, CodingKey {
            case items = "Items"
        }
    }

    // MARK: - BaseItemDto

    public struct BaseItemDto: Decodable, Sendable {
        public let id: String
        public let name: String?
        public let overview: String?
        public let collectionType: String?
        public let type: String?
        public let productionYear: Int?
        public let runTimeTicks: Int64?
        public let container: String?
        public let mediaSourceID: String?
        public let imageTags: [String: String]?
        public let backdropImageTags: [String]?
        public let seriesName: String?
        public let indexNumber: Int?
        public let parentIndexNumber: Int?
        public let parentId: String?
        public let communityRating: Double?
        public let officialRating: String?
        public let childCount: Int?
        public let recursiveItemCount: Int?
        public let status: String?
        public let providerIds: [String: String]?
        public let genres: [String]?
        public let premiereDate: String?
        public let endDate: String?
        public let dateCreated: String?
        public let userData: UserData?
        public let mediaSources: [MediaSourceInfo]?
        public let mediaStreams: [MediaStream]?
        public let people: [BaseItemPerson]?

        private enum CodingKeys: String, CodingKey {
            case id = "Id"
            case name = "Name"
            case overview = "Overview"
            case collectionType = "CollectionType"
            case type = "Type"
            case productionYear = "ProductionYear"
            case runTimeTicks = "RunTimeTicks"
            case container = "Container"
            case mediaSourceID = "MediaSourceId"
            case imageTags = "ImageTags"
            case backdropImageTags = "BackdropImageTags"
            case seriesName = "SeriesName"
            case indexNumber = "IndexNumber"
            case parentIndexNumber = "ParentIndexNumber"
            case parentId = "ParentId"
            case communityRating = "CommunityRating"
            case officialRating = "OfficialRating"
            case childCount = "ChildCount"
            case recursiveItemCount = "RecursiveItemCount"
            case status = "Status"
            case providerIds = "ProviderIds"
            case genres = "Genres"
            case premiereDate = "PremiereDate"
            case endDate = "EndDate"
            case dateCreated = "DateCreated"
            case userData = "UserData"
            case mediaSources = "MediaSources"
            case mediaStreams = "MediaStreams"
            case people = "People"
        }

        public struct UserData: Decodable, Sendable {
            public let played: Bool?
            public let isFavorite: Bool?
            public let playbackPositionTicks: Int64?
            public let lastPlayedDate: String?
            public let unplayedItemCount: Int?

            private enum CodingKeys: String, CodingKey {
                case played = "Played"
                case isFavorite = "IsFavorite"
                case playbackPositionTicks = "PlaybackPositionTicks"
                case lastPlayedDate = "LastPlayedDate"
                case unplayedItemCount = "UnplayedItemCount"
            }
        }

        public struct BaseItemPerson: Decodable, Sendable {
            public let id: String?
            public let name: String?
            public let role: String?
            public let type: String?
            public let primaryImageTag: String?

            private enum CodingKeys: String, CodingKey {
                case id = "Id"
                case name = "Name"
                case role = "Role"
                case type = "Type"
                case primaryImageTag = "PrimaryImageTag"
            }
        }
    }

    // MARK: - MediaSourceInfo

    public struct MediaSourceInfo: Decodable, Sendable {
        public let id: String?
        public let container: String?
        public let videoType: String?
        public let mediaStreams: [MediaStream]?
        /// Absolute server filesystem path of the source file (`Path`); `nil`
        /// unless the server exposes it. Surfaced in Technical Details.
        public let path: String?

        private enum CodingKeys: String, CodingKey {
            case id = "Id"
            case container = "Container"
            case videoType = "VideoType"
            case mediaStreams = "MediaStreams"
            case path = "Path"
        }
    }

    // MARK: - MediaStream

    public struct MediaStream: Decodable, Sendable {
        public let type: String?
        public let index: Int?
        public let language: String?
        public let displayTitle: String?
        public let codec: String?
        public let isDefault: Bool?
        public let isExternal: Bool?
        public let height: Int?
        public let width: Int?
        public let videoRange: String?
        public let bitRate: Int?

        private enum CodingKeys: String, CodingKey {
            case type = "Type"
            case index = "Index"
            case language = "Language"
            case displayTitle = "DisplayTitle"
            case codec = "Codec"
            case isDefault = "IsDefault"
            case isExternal = "IsExternal"
            case height = "Height"
            case width = "Width"
            case videoRange = "VideoRange"
            case bitRate = "BitRate"
        }
    }
}

// MARK: - BaseItemDto helpers

extension EmbyAPI.BaseItemDto {
    var kind: MediaItem.Kind? {
        switch type {
        case "Movie":   return .movie
        case "Episode": return .episode
        case "Series":  return .show
        case "Season":  return .season
        default:        return nil
        }
    }

    var isWatched: Bool { userData?.played ?? false }
    var isFavorite: Bool { userData?.isFavorite ?? false }

    var genreList: [String] { genres ?? [] }

    var contentRating: String? { officialRating }

    var releaseDate: Date? { Self.parseDate(premiereDate) }
    var dateAdded: Date?   { Self.parseDate(dateCreated) }

    var endYear: Int? {
        guard let endDate, !endDate.isEmpty else { return nil }
        return Self.parseDate(endDate).flatMap {
            Calendar(identifier: .gregorian).component(.year, from: $0) as Int?
        }
    }

    static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    var guids: MediaGuids {
        guard let ids = providerIds else { return MediaGuids() }
        let strings = ids.compactMap { key, value -> String? in
            guard !value.isEmpty else { return nil }
            return "\(key.lowercased())://\(value)"
        }
        return MediaGuids(guidStrings: strings)
    }

    var sourceMediaInfo: MediaInfo? {
        let videoStream = mediaStreams?.first(where: { $0.type == "Video" })
            ?? mediaSources?.first?.mediaStreams?.first(where: { $0.type == "Video" })
        let audioStream = mediaStreams?.first(where: { $0.type == "Audio" })
            ?? mediaSources?.first?.mediaStreams?.first(where: { $0.type == "Audio" })

        let containerStr = (mediaSources?.first?.container ?? container)?.lowercased()
        let codec = videoStream?.codec?.lowercased()
        guard containerStr != nil || codec != nil else { return nil }

        let h = videoStream?.height
        let w = videoStream?.width
        let resolution: String? = (w != nil && h != nil) ? "\(w!)x\(h!)" : nil
        let kbps = videoStream?.bitRate.map { $0 / 1000 }

        return MediaInfo(
            videoCodec: codec,
            audioCodec: audioStream?.codec?.lowercased(),
            videoResolution: resolution,
            bitrateKbps: kbps,
            container: containerStr,
            filePath: mediaSources?.first?.path
        )
    }

    var audioTracks: [MediaAudioTrack] {
        let streams = mediaStreams ?? mediaSources?.first?.mediaStreams ?? []
        return streams
            .filter { $0.type == "Audio" }
            .compactMap { stream -> MediaAudioTrack? in
                guard let index = stream.index else { return nil }
                let title = stream.displayTitle ?? stream.language ?? "Track \(index)"
                return MediaAudioTrack(
                    id: String(index),
                    title: title,
                    languageCode: stream.language,
                    codec: stream.codec,
                    isSelected: stream.isDefault ?? false
                )
            }
    }

    var subtitleTracks: [MediaSubtitleTrack] {
        let streams = mediaStreams ?? mediaSources?.first?.mediaStreams ?? []
        return streams
            .filter { $0.type == "Subtitle" }
            .compactMap { stream -> MediaSubtitleTrack? in
                guard let index = stream.index else { return nil }
                let title = stream.displayTitle ?? stream.language ?? "Subtitle \(index)"
                return MediaSubtitleTrack(
                    id: String(index),
                    title: title,
                    languageCode: stream.language,
                    codec: stream.codec,
                    isForced: stream.isExternal ?? false,
                    isSelected: stream.isDefault ?? false
                )
            }
    }
}
