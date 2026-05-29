import Foundation

/// Runs Plex's PIN auth flow.
///
/// 1. Ask plex.tv for a new PIN: `POST /api/v2/pins`. We get back an `id` and a
///    short human-readable `code`.
/// 2. Show the user the `code` and tell them to enter it at
///    `https://www.plex.tv/link`.
/// 3. Poll `GET /api/v2/pins/{id}` until either:
///    - `authToken` becomes non-`nil` → we have the user's token, sign-in done.
///    - the PIN's `expiresAt` passes → we give up with `.expired`.
///    - the timeout passes → we give up with `.timedOut`.
/// 4. Store the token in `KeychainStore` (caller's responsibility — this actor
///    returns the token, doesn't persist it).
public actor PlexAuthClient {
    private let api: any APIClient
    private let configuration: PlexConfiguration
    private let decoder: JSONDecoder
    private let baseURL: URL

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

    // MARK: - Step 1 — request a PIN

    public func requestPIN(strong: Bool = true) async throws -> PlexAPI.PIN {
        var components = URLComponents(url: baseURL.appendingPathComponent("/api/v2/pins"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "strong", value: strong ? "true" : "false")]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        applyCommonHeaders(to: &request)

        return try await api.decode(PlexAPI.PIN.self, from: request, decoder: decoder)
    }

    // MARK: - Step 2 — the user pin URL we display

    public nonisolated func linkURL(for pin: PlexAPI.PIN) -> URL {
        // plex.tv/link is the page where the user enters the displayed code.
        URL(string: "https://www.plex.tv/link?pin=\(pin.code)")!
    }

    // MARK: - Step 3 — poll until auth or timeout

    public func checkPIN(id: Int) async throws -> PlexAPI.PIN {
        let url = baseURL.appendingPathComponent("/api/v2/pins/\(id)")
        var request = URLRequest(url: url)
        applyCommonHeaders(to: &request)
        return try await api.decode(PlexAPI.PIN.self, from: request, decoder: decoder)
    }

    /// Poll `checkPIN` every `interval` until the PIN carries an `authToken`,
    /// the PIN expires, or `timeout` elapses. Returns the auth token.
    public func pollForToken(
        pinID: Int,
        interval: Duration = .seconds(2),
        timeout: Duration = .seconds(300)
    ) async throws -> String {
        let deadline = ContinuousClock.now.advanced(by: timeout)

        while ContinuousClock.now < deadline {
            let pin = try await checkPIN(id: pinID)

            if let token = pin.authToken, !token.isEmpty {
                return token
            }
            if let expiresAt = pin.expiresAt, expiresAt < .now {
                throw PlexAuthError.expired
            }

            try Task.checkCancellation()
            try await Task.sleep(for: interval)
        }

        throw PlexAuthError.timedOut
    }

    // MARK: - Helpers

    private func applyCommonHeaders(to request: inout URLRequest) {
        for (key, value) in configuration.commonHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }
}

public enum PlexAuthError: Error, Sendable, Equatable {
    case expired
    case timedOut
}
