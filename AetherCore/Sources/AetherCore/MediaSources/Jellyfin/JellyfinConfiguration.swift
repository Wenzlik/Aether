import Foundation

/// Static identity Aether sends to a Jellyfin server on every request.
///
/// Jellyfin authenticates with an `Authorization: MediaBrowser …` header that
/// carries the client name, device, a stable per-install device id, the app
/// version, and (once signed in) the access token. The `deviceID` must persist
/// across launches — Jellyfin scopes sessions and Quick Connect to it — so we
/// round-trip it via `KeychainStore` at app start, exactly like Plex's
/// `clientIdentifier`.
public struct JellyfinConfiguration: Sendable {
    public let client: String
    public let version: String
    public let deviceName: String
    public let deviceID: String

    public init(
        client: String,
        version: String,
        deviceName: String,
        deviceID: String
    ) {
        self.client = client
        self.version = version
        self.deviceName = deviceName
        self.deviceID = deviceID
    }

    /// The `Authorization` header value. `token` is omitted before sign-in
    /// (Quick Connect initiation works unauthenticated) and included afterwards
    /// so the server scopes the request to the signed-in user.
    public func authorizationHeader(token: String? = nil) -> String {
        var parts = [
            "Client=\(quoted(client))",
            "Device=\(quoted(deviceName))",
            "DeviceId=\(quoted(deviceID))",
            "Version=\(quoted(version))"
        ]
        if let token, !token.isEmpty {
            parts.append("Token=\(quoted(token))")
        }
        return "MediaBrowser " + parts.joined(separator: ", ")
    }

    /// Headers sent on every Jellyfin API request. JSON is requested explicitly.
    public func commonHeaders(token: String? = nil) -> [String: String] {
        [
            "Accept": "application/json",
            "Authorization": authorizationHeader(token: token)
        ]
    }

    private func quoted(_ value: String) -> String {
        "\"\(value)\""
    }
}
