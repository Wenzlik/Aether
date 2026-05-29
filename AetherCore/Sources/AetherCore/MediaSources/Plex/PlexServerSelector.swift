import Foundation

/// Pure logic for turning a list of `PlexAPI.Resource`s into "the server we
/// should talk to next."
///
/// No I/O, no actor — every method is a deterministic function of its input.
/// That keeps it trivially testable and lets the caller mix-and-match: the
/// production flow calls `selectBest(from:)`, but a future Settings → Server
/// Picker screen will reuse `mediaServers(from:)` + `score(server:connection:)`
/// to show all candidates ranked.
///
/// ## Ranking strategy (intentionally simple)
///
/// We compose a single integer score per `(server, connection)` pair. Higher
/// wins. The weights are chosen so each tier is one order of magnitude apart;
/// no two tiers can swap.
///
/// | Bit | Weight | Reason |
/// |-----|--------|--------|
/// | local connection           | +1000 | LAN beats anything WAN — latency, bandwidth, no Plex relay cost |
/// | direct (non-relay)         | +100  | Direct is more reliable than relay; relay has Plex's bandwidth caps |
/// | HTTPS                      | +10   | Trust the cert + plex.direct hostnames; consistent with Plex's defaults |
/// | owned server               | +1    | Tiebreaker; the user's own server beats a friend-shared one |
///
/// ## Tradeoffs
///
/// - **No RTT probing.** A real probe would HEAD `/identity` on each candidate
///   with a short timeout and race the winners. We deliberately don't do this
///   in the first server-discovery PR: it adds a network step, complicates
///   testing, and the static ranking already produces the right answer in the
///   common cases (local + direct + https). RTT becomes a tiebreaker layer
///   later by sorting same-score candidates with a probe-based comparator.
/// - **No "friends' servers" handling.** Shared servers are included if they
///   provide `server` and carry an `accessToken` — they just sit a tier below
///   owned servers via the `+1` tiebreaker. A future Settings flow will let
///   the user explicitly pick among them.
/// - **No transcoding awareness.** Connection quality, not server capacity.
///   That's a runtime concern handled at playback time by Plex itself.
public struct PlexServerSelector: Sendable {

    public init() {}

    // MARK: - Filtering

    /// Keep only the resources that:
    /// - advertise the `server` provider (`provides` field, comma-separated),
    /// - have a per-server `accessToken` (otherwise we can't authenticate),
    /// - have at least one reachable connection in the list.
    public func mediaServers(from resources: [PlexAPI.Resource]) -> [PlexAPI.Resource] {
        resources.filter { resource in
            resource.providesServer
                && (resource.accessToken?.isEmpty == false)
                && !resource.connections.isEmpty
        }
    }

    // MARK: - Scoring

    /// Score a `(server, connection)` pair. Higher = preferred. Pure.
    public func score(
        server: PlexAPI.Resource,
        connection: PlexAPI.Resource.Connection
    ) -> Int {
        var score = 0
        if connection.local        { score += 1000 }
        if !connection.relay       { score += 100  }
        if connection.connectionProtocol == "https" { score += 10 }
        if server.owned            { score += 1   }
        return score
    }

    // MARK: - Selection

    /// Pick the single best `(server, connection)` pair across all candidates.
    /// Returns `nil` when no resource is a usable Plex Media Server.
    public func selectBest(
        from resources: [PlexAPI.Resource]
    ) -> Selection? {
        var best: (server: PlexAPI.Resource, connection: PlexAPI.Resource.Connection, score: Int)?

        for server in mediaServers(from: resources) {
            for connection in server.connections {
                let s = score(server: server, connection: connection)
                if best == nil || s > best!.score {
                    best = (server, connection, s)
                }
            }
        }

        return best.map { Selection(server: $0.server, connection: $0.connection, score: $0.score) }
    }

    /// The picked pair plus its score, surfaced so UI/tests can introspect.
    public struct Selection: Sendable, Equatable {
        public let server: PlexAPI.Resource
        public let connection: PlexAPI.Resource.Connection
        public let score: Int

        public init(server: PlexAPI.Resource, connection: PlexAPI.Resource.Connection, score: Int) {
            self.server = server
            self.connection = connection
            self.score = score
        }

        /// Build a `PlexServerRecord` ready for persistence.
        ///
        /// Persists **all** of the chosen server's connections, ranked best-first
        /// by the same scoring used to pick the server. The runtime source
        /// (`PlexMediaSource`) probes them in this order, so leaving the LAN
        /// just means falling through to the first reachable remote / relay
        /// connection instead of being stuck on a dead local address.
        public func makeRecord() -> PlexServerRecord {
            let selector = PlexServerSelector()
            let ranked = server.connections
                .sorted { selector.score(server: server, connection: $0) > selector.score(server: server, connection: $1) }
                .map { PlexServerRecord.Connection(uri: $0.uri, isLocal: $0.local, isRelay: $0.relay) }

            return PlexServerRecord(
                clientIdentifier: server.clientIdentifier,
                name: server.name,
                // The server access token is required for filtering, so this
                // force-unwrap is safe in practice. We fall back to "" just to
                // avoid ever crashing in a release build if upstream changes.
                accessToken: server.accessToken ?? "",
                connections: ranked
            )
        }
    }
}
