import Foundation

/// The persisted identity of a Plex Media Server Aether has been told to use.
///
/// Lives in `KeychainStore` because it carries a server access token. Re-read
/// on every launch by `AppSession.start()`; if present, `AppSession` builds a
/// live `PlexMediaSource` against it.
///
/// We persist **all** of the server's connections (ranked, best first) — not
/// just the single best one. The best connection at discovery time is usually
/// the LAN address, which is unreachable when the user later leaves the house.
/// Keeping the full ranked list lets `PlexMediaSource` fail over to a remote /
/// relay connection at runtime instead of being stuck on a dead LAN URL.
public struct PlexServerRecord: Codable, Sendable, Equatable {
    /// The PMS's own UUID — stable across IP changes, network moves, restarts.
    public let clientIdentifier: String

    /// Human-readable server name (e.g. *"DS418"*). For UI only.
    public let name: String

    /// Per-server access token. Plex issues one per server in the resources
    /// response; we prefer it over the account-wide token so blast radius
    /// stays scoped if any one server is later compromised.
    public let accessToken: String

    /// All known connections to this server, **ranked best-first** by
    /// `PlexServerSelector`. `PlexMediaSource` probes them in this order and
    /// uses the first that responds.
    public let connections: [Connection]

    public init(
        clientIdentifier: String,
        name: String,
        accessToken: String,
        connections: [Connection]
    ) {
        self.clientIdentifier = clientIdentifier
        self.name = name
        self.accessToken = accessToken
        self.connections = connections
    }

    public struct Connection: Codable, Sendable, Equatable {
        /// Absolute URI, e.g. `https://192-168-1-10.uuid.plex.direct:32400`.
        public let uri: String
        public let isLocal: Bool
        public let isRelay: Bool

        public init(uri: String, isLocal: Bool, isRelay: Bool) {
            self.uri = uri
            self.isLocal = isLocal
            self.isRelay = isRelay
        }

        public var url: URL? { URL(string: uri) }
    }

    /// The preferred (first) connection's URL, if any. Convenience for UI /
    /// diagnostics; the source itself iterates all of `connections`.
    public var primaryURL: URL? {
        connections.first?.url
    }
}
