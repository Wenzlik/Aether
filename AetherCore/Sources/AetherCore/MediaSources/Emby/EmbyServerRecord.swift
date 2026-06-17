import Foundation

/// A persisted Emby server connection: the base URL, access token, user ID,
/// and a display name. Stored as JSON in the Keychain by `EmbyServerStore`.
public struct EmbyServerRecord: Codable, Sendable, Equatable {
    public let baseURLString: String
    public let accessToken: String
    public let userID: String
    public let serverName: String

    public init(baseURLString: String, accessToken: String, userID: String, serverName: String) {
        self.baseURLString = baseURLString
        self.accessToken = accessToken
        self.userID = userID
        self.serverName = serverName
    }

    public var baseURL: URL? { URL(string: baseURLString) }
}
