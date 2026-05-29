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
}
