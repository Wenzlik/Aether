import Foundation

/// Persisted shape of a signed-in Jellyfin server. Simpler than
/// `PlexServerRecord` — Jellyfin is one base URL the user typed, with no
/// central directory or ranked connection set to fail over between.
public struct JellyfinServerRecord: Codable, Sendable, Equatable {
    public let baseURLString: String
    public let accessToken: String
    public let userID: String
    public let serverName: String

    public init(
        baseURLString: String,
        accessToken: String,
        userID: String,
        serverName: String
    ) {
        self.baseURLString = baseURLString
        self.accessToken = accessToken
        self.userID = userID
        self.serverName = serverName
    }

    public var baseURL: URL? { URL(string: baseURLString) }
}
