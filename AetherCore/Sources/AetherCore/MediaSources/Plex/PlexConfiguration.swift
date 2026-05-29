import Foundation

/// Static identity Aether sends to Plex on every request.
///
/// Plex uses the `X-Plex-*` headers to identify which app is asking, which
/// device, and which install. The `clientIdentifier` is the stable per-install
/// UUID — Plex uses it to scope sessions and resume points, so it must persist
/// across launches (we round-trip it via `KeychainStore` at app start).
public struct PlexConfiguration: Sendable {
    public let product: String
    public let version: String
    public let clientIdentifier: String
    public let deviceName: String
    public let platform: String
    public let platformVersion: String

    public init(
        product: String,
        version: String,
        clientIdentifier: String,
        deviceName: String,
        platform: String,
        platformVersion: String
    ) {
        self.product = product
        self.version = version
        self.clientIdentifier = clientIdentifier
        self.deviceName = deviceName
        self.platform = platform
        self.platformVersion = platformVersion
    }

    /// Headers sent on every plex.tv and PMS request. JSON is requested
    /// explicitly because Plex defaults to XML if the header isn't set.
    public var commonHeaders: [String: String] {
        [
            "Accept": "application/json",
            "X-Plex-Product": product,
            "X-Plex-Version": version,
            "X-Plex-Client-Identifier": clientIdentifier,
            "X-Plex-Device-Name": deviceName,
            "X-Plex-Platform": platform,
            "X-Plex-Platform-Version": platformVersion
        ]
    }
}
