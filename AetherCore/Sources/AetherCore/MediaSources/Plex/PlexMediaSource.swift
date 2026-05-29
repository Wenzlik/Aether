import Foundation

/// A Plex Media Server connection wired up as an Aether `MediaSource`.
///
/// 0.2 skeleton: holds the configuration, the auth token, the chosen
/// connection (base URL), and an `APIClient`. The library / item listings
/// remain stubs in this PR — they land alongside the metadata mapping in a
/// follow-up. The shape is set so the follow-up doesn't touch view code.
public actor PlexMediaSource: MediaSource {
    public let id: MediaSourceID
    public let displayName: String

    private let api: any APIClient
    private let configuration: PlexConfiguration
    private let baseURL: URL
    private let accessToken: String

    public init(
        serverID: String,
        displayName: String,
        baseURL: URL,
        accessToken: String,
        configuration: PlexConfiguration,
        api: any APIClient
    ) {
        self.id = .plex(serverID: serverID)
        self.displayName = displayName
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.configuration = configuration
        self.api = api
    }

    // MARK: - MediaSource

    public func libraries() async throws -> [Library] {
        // TODO(0.2): GET /library/sections; map directories → Library.
        []
    }

    public func items(in libraryID: Library.ID) async throws -> [MediaItem] {
        // TODO(0.2): GET /library/sections/{key}/all; map metadata → MediaItem.
        []
    }

    // MARK: - Request construction (used by future endpoints + tests)

    /// Build a `URLRequest` against this server with the configured headers
    /// plus this connection's `X-Plex-Token`. Exposed for future endpoint
    /// implementations and for unit testing the header set.
    nonisolated func request(forPath path: String, queryItems: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        var request = URLRequest(url: components.url!)
        for (key, value) in configuration.commonHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue(accessToken, forHTTPHeaderField: "X-Plex-Token")
        return request
    }
}
