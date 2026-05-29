import Foundation

/// Fetches the list of Plex resources (servers + devices) the authenticated
/// user has access to.
///
/// Backed by `GET https://plex.tv/api/v2/resources`. Returns the raw decoded
/// array — filtering down to actual media servers and picking the best
/// connection is `PlexServerSelector`'s job.
public actor PlexResourceClient {
    private let api: any APIClient
    private let configuration: PlexConfiguration
    private let baseURL: URL
    private let decoder: JSONDecoder

    public init(
        api: any APIClient,
        configuration: PlexConfiguration,
        baseURL: URL = URL(string: "https://plex.tv")!
    ) {
        self.api = api
        self.configuration = configuration
        self.baseURL = baseURL

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// Fetch the resource list using the supplied account token.
    ///
    /// Plex returns more fields when you ask for them — the two flags below
    /// matter for connection diversity. We default both to `true` because
    /// removing them means we'd miss working connections; the selector throws
    /// out anything we don't actually want.
    public func resources(
        token: String,
        includeHttps: Bool = true,
        includeRelay: Bool = true
    ) async throws -> [PlexAPI.Resource] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/api/v2/resources"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "includeHttps", value: includeHttps ? "1" : "0"),
            URLQueryItem(name: "includeRelay", value: includeRelay ? "1" : "0")
        ]

        var request = URLRequest(url: components.url!)
        for (key, value) in configuration.commonHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")

        return try await api.decode([PlexAPI.Resource].self, from: request, decoder: decoder)
    }
}
