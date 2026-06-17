import Foundation

/// Emby uses the same `MediaBrowser` Authorization header format as Jellyfin.
/// The token is omitted from pre-auth requests (device registration / Quick
/// Connect initiation) and included once we hold an access token.
public struct EmbyConfiguration: Sendable {
    public let client: String
    public let version: String
    public let deviceName: String
    public let deviceID: String

    public init(client: String, version: String, deviceName: String, deviceID: String) {
        self.client = client
        self.version = version
        self.deviceName = deviceName
        self.deviceID = deviceID
    }

    /// Returns the full `Authorization` header dictionary for every Emby request.
    /// `token` is `nil` before authentication; it is included in the header once
    /// the Quick Connect exchange completes and we hold an access token.
    public func commonHeaders(token: String?) -> [String: String] {
        var parts = [
            "Client=\"\(client)\"",
            "Device=\"\(deviceName)\"",
            "DeviceId=\"\(deviceID)\"",
            "Version=\"\(version)\""
        ]
        if let token { parts.append("Token=\"\(token)\"") }
        return ["Authorization": "MediaBrowser \(parts.joined(separator: ", "))"]
    }
}
