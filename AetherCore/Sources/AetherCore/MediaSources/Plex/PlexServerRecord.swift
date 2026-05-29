import Foundation

/// The persisted identity of a Plex Media Server Aether has been told to use.
///
/// Lives in `KeychainStore` because it carries a server access token. Re-read
/// on every launch by `AppSession.start()`; if present, `AppSession` builds a
/// live `PlexMediaSource` against it. If the user signs out (or asks Aether
/// to pick a different server), the record is cleared.
///
/// Deliberately small: we persist *what's needed to talk to the server next
/// launch* — nothing about libraries or items. Those are queried fresh.
public struct PlexServerRecord: Codable, Sendable, Equatable {
    /// The PMS's own UUID — stable across IP changes, network moves, restarts.
    public let clientIdentifier: String

    /// Human-readable server name (e.g. *"MyTower"*). For UI only.
    public let name: String

    /// Per-server access token. Plex issues one per server in the resources
    /// response; we prefer it over the account-wide token so blast radius
    /// stays scoped if any one server is later compromised.
    public let accessToken: String

    /// The selected connection's URI as a string (e.g.
    /// `"https://192-168-1-10.uuid.plex.direct:32400"`).
    public let baseURLString: String

    /// Whether the selected connection is on the LAN. Stored for diagnostics
    /// and for the next launch's UI ("Connected locally to MyTower").
    public let isLocalConnection: Bool

    /// Whether the selected connection routes through Plex's relay. Mostly for
    /// surfacing in Settings later — "via Plex relay" matters to users.
    public let isRelayConnection: Bool

    public init(
        clientIdentifier: String,
        name: String,
        accessToken: String,
        baseURLString: String,
        isLocalConnection: Bool,
        isRelayConnection: Bool
    ) {
        self.clientIdentifier = clientIdentifier
        self.name = name
        self.accessToken = accessToken
        self.baseURLString = baseURLString
        self.isLocalConnection = isLocalConnection
        self.isRelayConnection = isRelayConnection
    }

    public var baseURL: URL? {
        URL(string: baseURLString)
    }
}
