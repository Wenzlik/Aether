import Foundation

/// Runs Jellyfin's Quick Connect sign-in flow against a user-entered server URL.
///
/// 1. Validate the URL is a Jellyfin server: `GET /System/Info/Public`.
/// 2. Confirm Quick Connect is enabled: `GET /QuickConnect/Enabled` (bare bool).
/// 3. Initiate: `GET /QuickConnect/Initiate` → `{Secret, Code}`. Show the user
///    the `Code`; they approve it in their Jellyfin dashboard / another client.
/// 4. Poll `GET /QuickConnect/Connect?Secret=…` until `Authenticated`, then
///    `POST /Users/AuthenticateWithQuickConnect {Secret}` → access token + user.
///
/// Mirrors `PlexAuthClient`: this actor returns the result; the caller persists
/// it. Pre-auth requests carry the `MediaBrowser` Authorization header WITHOUT a
/// token (Client/Device/DeviceId only) — Quick Connect is keyed by the device.
public actor JellyfinAuthClient {
    private let api: any APIClient
    private let configuration: JellyfinConfiguration
    private let decoder: JSONDecoder

    public init(api: any APIClient, configuration: JellyfinConfiguration) {
        self.api = api
        self.configuration = configuration
        self.decoder = JSONDecoder()
    }

    // MARK: - Step 1 — validate the server

    public func publicInfo(baseURL: URL) async throws -> JellyfinAPI.PublicSystemInfo {
        let request = makeRequest(baseURL: baseURL, path: "/System/Info/Public")
        do {
            return try await api.decode(JellyfinAPI.PublicSystemInfo.self, from: request, decoder: decoder)
        } catch {
            throw JellyfinAuthError.invalidServer
        }
    }

    // MARK: - Step 2 — is Quick Connect on?

    public func quickConnectEnabled(baseURL: URL) async throws -> Bool {
        let request = makeRequest(baseURL: baseURL, path: "/QuickConnect/Enabled")
        // The endpoint returns a bare JSON boolean.
        return (try? await api.decode(Bool.self, from: request, decoder: decoder)) ?? false
    }

    // MARK: - Step 3 — initiate

    public func initiateQuickConnect(baseURL: URL) async throws -> JellyfinAPI.QuickConnectResult {
        guard try await quickConnectEnabled(baseURL: baseURL) else {
            throw JellyfinAuthError.notEnabled
        }
        let request = makeRequest(baseURL: baseURL, path: "/QuickConnect/Initiate")
        return try await api.decode(JellyfinAPI.QuickConnectResult.self, from: request, decoder: decoder)
    }

    // MARK: - Step 4 — poll then authenticate

    /// Poll `/QuickConnect/Connect` until the user approves the code, then
    /// exchange the secret for an access token. Throws `.timedOut` if the user
    /// never approves within `timeout`.
    public func pollForAuthentication(
        baseURL: URL,
        secret: String,
        interval: Duration = .seconds(2),
        timeout: Duration = .seconds(300)
    ) async throws -> JellyfinAPI.AuthenticationResult {
        let deadline = ContinuousClock.now.advanced(by: timeout)

        while ContinuousClock.now < deadline {
            var components = URLComponents(
                url: baseURL.appendingPathComponent("/QuickConnect/Connect"),
                resolvingAgainstBaseURL: false
            )!
            components.queryItems = [URLQueryItem(name: "Secret", value: secret)]
            var request = URLRequest(url: components.url!)
            applyHeaders(to: &request)

            let result = try await api.decode(JellyfinAPI.QuickConnectResult.self, from: request, decoder: decoder)
            if result.authenticated {
                return try await authenticate(baseURL: baseURL, secret: secret)
            }

            try Task.checkCancellation()
            try await Task.sleep(for: interval)
        }

        throw JellyfinAuthError.timedOut
    }

    private func authenticate(baseURL: URL, secret: String) async throws -> JellyfinAPI.AuthenticationResult {
        var request = URLRequest(url: baseURL.appendingPathComponent("/Users/AuthenticateWithQuickConnect"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyHeaders(to: &request)
        request.httpBody = try JSONEncoder().encode(["Secret": secret])
        return try await api.decode(JellyfinAPI.AuthenticationResult.self, from: request, decoder: decoder)
    }

    // MARK: - Helpers

    private func makeRequest(baseURL: URL, path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        applyHeaders(to: &request)
        return request
    }

    private func applyHeaders(to request: inout URLRequest) {
        for (key, value) in configuration.commonHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }
}

public enum JellyfinAuthError: Error, Sendable, Equatable {
    case invalidServer
    case notEnabled
    case timedOut
}
