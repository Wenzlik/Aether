import Foundation

/// Talks to Plex Home's managed-user endpoints.
///
/// After the PIN flow yields the **account (admin) token**, a Plex Home account
/// can carry several profiles — each with its own watch state, libraries and
/// restrictions. The flow is:
///
/// 1. `users(adminToken:)` → `GET /api/v2/home/users` lists the profiles. A
///    non-Home account returns a single user; callers skip selection then.
/// 2. `switchUser(uuid:pin:adminToken:)` → `POST /api/v2/home/users/{uuid}/switch`
///    returns that profile's **scoped token**, which replaces the admin token
///    for resources / playback. PIN-protected profiles need the `pin`.
public actor PlexHomeClient {
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
        self.decoder = JSONDecoder()
    }

    /// List the Home profiles on the account that owns `adminToken`.
    public func users(adminToken: String) async throws -> [PlexAPI.HomeUser] {
        var request = URLRequest(url: baseURL.appendingPathComponent("/api/v2/home/users"))
        applyHeaders(to: &request, token: adminToken)
        let response = try await api.decode(PlexAPI.HomeUsersResponse.self, from: request, decoder: decoder)
        return response.users
    }

    /// Switch to a Home profile, returning its scoped auth token.
    /// - Throws `PlexHomeError.invalidPIN` on 401/403 (missing or wrong PIN),
    ///   `PlexHomeError.noToken` if the switch succeeds without a token.
    public func switchUser(uuid: String, pin: String?, adminToken: String) async throws -> String {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/api/v2/home/users/\(uuid)/switch"),
            resolvingAgainstBaseURL: false)!
        if let pin, !pin.isEmpty {
            components.queryItems = [URLQueryItem(name: "pin", value: pin)]
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        applyHeaders(to: &request, token: adminToken)

        do {
            // Plex returns 201 Created on a successful switch; the response omits
            // `admin`/`restricted` (HomeUser decodes those leniently).
            let user = try await api.decode(PlexAPI.HomeUser.self, from: request, decoder: decoder)
            guard let token = user.authToken, !token.isEmpty else { throw PlexHomeError.noToken }
            return token
        } catch let APIClientError.unexpectedStatus(code) where code == 401 || code == 403 {
            throw PlexHomeError.invalidPIN
        }
    }

    private func applyHeaders(to request: inout URLRequest, token: String) {
        for (key, value) in configuration.commonHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
    }
}

public enum PlexHomeError: Error, Sendable, Equatable {
    /// The profile is PIN-protected and the PIN was missing or wrong.
    case invalidPIN
    /// The switch response carried no token.
    case noToken
}

/// The outcome of a completed Plex sign-in. Carries the working token (the
/// picked profile's scoped token, or the account token when there's no Home),
/// the original admin token (kept so Settings can re-list / switch profiles),
/// and the chosen profile for display + "remember the user".
public struct PlexSignInResult: Sendable, Equatable {
    public let token: String
    public let adminToken: String
    public let user: PlexAPI.HomeUser?

    public init(token: String, adminToken: String, user: PlexAPI.HomeUser?) {
        self.token = token
        self.adminToken = adminToken
        self.user = user
    }
}

/// Minimal, persistable record of the active Home profile — enough to restore
/// the picker selection and show "who's watching" across launches, without
/// storing the scoped token here (that lives in the Keychain token slot).
public struct PlexHomeUserRef: Codable, Sendable, Equatable {
    public let uuid: String
    public let title: String
    public let thumb: String?

    public init(uuid: String, title: String, thumb: String?) {
        self.uuid = uuid
        self.title = title
        self.thumb = thumb
    }

    public init(user: PlexAPI.HomeUser) {
        self.init(uuid: user.uuid, title: user.title, thumb: user.thumb)
    }
}
