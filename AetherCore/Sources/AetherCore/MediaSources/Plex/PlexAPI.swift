import Foundation

/// Namespace for `Decodable` shapes returned by plex.tv and PMS endpoints.
///
/// Kept under one type so call sites read clearly (`PlexAPI.PIN`, `PlexAPI.Resource`)
/// and so we don't pollute the top-level AetherCore namespace with Plex-only types.
public enum PlexAPI {

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
        /// Playable media. Present on movies + episodes; absent on containers
        /// like shows and seasons (you play their children, not them).
        public let media: [Media]?

        public var kind: MediaItem.Kind {
            switch type {
            case "movie":   return .movie
            case "episode": return .episode
            case "show":    return .show
            default:        return .movie  // best-effort fallback
            }
        }

        /// The first part's relative `key` — the direct-play file path.
        /// `/library/sections/{key}/all` includes Media + Part inline for
        /// movies and episodes, so no extra request is needed to resolve it.
        public var firstPartKey: String? {
            media?.first?.part?.first?.key
        }

        enum CodingKeys: String, CodingKey {
            case ratingKey, type, title, summary, year, duration, thumb, art
            case media = "Media"
        }

        public struct Media: Decodable, Sendable, Equatable {
            public let part: [Part]?

            enum CodingKeys: String, CodingKey {
                case part = "Part"
            }
        }

        public struct Part: Decodable, Sendable, Equatable {
            /// Relative path to the original file, e.g.
            /// `/library/parts/12345/1700000000/file.mkv`.
            public let key: String?
        }
    }
}
