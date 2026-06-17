import Foundation

/// Emby Quick Connect authentication flow.
///
/// Step-by-step:
/// 1. `GET /System/Info/Public` → validate the server is reachable and get its name.
/// 2. `GET /QuickConnect/Enabled` → bare `true`/`false`; fail fast if disabled.
/// 3. `GET /QuickConnect/Initiate` → `{ Secret, Code }`.
/// 4. Poll `GET /QuickConnect/Connect?Secret=…` every `interval` until
///    `Authenticated == true` (or `timeout` elapses).
/// 5. `POST /Users/AuthenticateWithQuickConnect { Secret }` → access token + user ID.
///
/// The flow is identical to Jellyfin — both servers inherit it from the same
/// upstream codebase.
public actor EmbyAuthClient {
    private let api: any APIClient
    private let configuration: EmbyConfiguration

    public init(api: any APIClient, configuration: EmbyConfiguration) {
        self.api = api
        self.configuration = configuration
    }

    // MARK: - Public API

    /// Validate the server and return its public info. Throws if unreachable.
    public func publicInfo(baseURL: URL) async throws -> EmbyAPI.PublicSystemInfo {
        let request = makeRequest(baseURL: baseURL, path: "/System/Info/Public")
        return try await api.decode(EmbyAPI.PublicSystemInfo.self, from: request)
    }

    /// Initiate a Quick Connect session and return the `{ Secret, Code }` pair.
    public func initiateQuickConnect(baseURL: URL) async throws -> (secret: String, code: String) {
        guard try await quickConnectEnabled(baseURL: baseURL) else {
            throw EmbyAuthError.notEnabled
        }
        let request = makeRequest(baseURL: baseURL, path: "/QuickConnect/Initiate")
        let result = try await api.decode(EmbyAPI.QuickConnectResult.self, from: request)
        return (result.secret, result.code)
    }

    /// Poll until the user approves the Quick Connect code, then exchange the
    /// secret for an access token. Throws `EmbyAuthError.timedOut` if the user
    /// doesn't approve within `timeout`.
    public func pollForAuthentication(
        baseURL: URL,
        secret: String,
        interval: Duration = .seconds(2),
        timeout: Duration = .seconds(300)
    ) async throws -> EmbyAPI.AuthenticationResult {
        let deadline = ContinuousClock.now + timeout

        while ContinuousClock.now < deadline {
            try await Task.sleep(for: interval)
            try Task.checkCancellation()

            let request = makeRequest(
                baseURL: baseURL,
                path: "/QuickConnect/Connect",
                queryItems: [URLQueryItem(name: "Secret", value: secret)]
            )
            guard let result = try? await api.decode(EmbyAPI.QuickConnectResult.self, from: request),
                  result.authenticated else { continue }

            return try await authenticateWithSecret(secret, baseURL: baseURL)
        }
        throw EmbyAuthError.timedOut
    }

    // MARK: - Private

    private func quickConnectEnabled(baseURL: URL) async throws -> Bool {
        let request = makeRequest(baseURL: baseURL, path: "/QuickConnect/Enabled")
        guard let (data, _) = try? await api.data(for: request) else { return false }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.lowercased() == "true"
    }

    private func authenticateWithSecret(_ secret: String, baseURL: URL) async throws -> EmbyAPI.AuthenticationResult {
        var request = makeRequest(baseURL: baseURL, path: "/Users/AuthenticateWithQuickConnect")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["Secret": secret]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await api.decode(EmbyAPI.AuthenticationResult.self, from: request)
    }

    private func makeRequest(baseURL: URL, path: String, queryItems: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !queryItems.isEmpty { components.queryItems = queryItems }
        var request = URLRequest(url: components.url!)
        for (key, value) in configuration.commonHeaders(token: nil) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }
}

// MARK: - Errors

public enum EmbyAuthError: Error {
    case notEnabled
    case timedOut
}
