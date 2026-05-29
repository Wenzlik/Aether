import Foundation

/// A Plex Media Server connection wired up as an Aether `MediaSource`.
///
/// Holds the configuration, the auth token, the **ranked list of connections**,
/// and an `APIClient`. Resolves which connection actually works at runtime by
/// probing `/identity` in rank order — so the same source object plays on the
/// LAN at home and over a remote / relay connection away from home, without
/// re-running discovery.
///
/// Implements:
/// - `libraries()` → `GET /library/sections`
/// - `items(in:)`  → `GET /library/sections/{key}/all`
public actor PlexMediaSource: MediaSource {
    public let id: MediaSourceID
    public let displayName: String

    private let api: any APIClient
    private let configuration: PlexConfiguration
    private let accessToken: String
    private let connections: [PlexServerRecord.Connection]
    private let decoder: JSONDecoder

    /// How long a single connection probe is allowed to take before we move on
    /// to the next candidate. Kept short so leaving the LAN fails over quickly
    /// instead of hanging on the default 60s URLSession timeout.
    private let probeTimeout: TimeInterval

    /// The connection we've confirmed reachable this session. Lazily resolved
    /// on the first request and reused afterwards.
    private var resolvedBaseURL: URL?

    public init(
        serverID: String,
        displayName: String,
        accessToken: String,
        connections: [PlexServerRecord.Connection],
        configuration: PlexConfiguration,
        api: any APIClient,
        probeTimeout: TimeInterval = 4
    ) {
        self.id = .plex(serverID: serverID)
        self.displayName = displayName
        self.accessToken = accessToken
        self.connections = connections
        self.configuration = configuration
        self.api = api
        self.probeTimeout = probeTimeout
        self.decoder = JSONDecoder()
    }

    // MARK: - MediaSource

    public func libraries() async throws -> [Library] {
        let base = try await resolveBaseURL()
        let request = request(base: base, path: "/library/sections")
        let response = try await api.decode(
            PlexAPI.LibrarySectionsResponse.self,
            from: request,
            decoder: decoder
        )
        let directories = response.mediaContainer.directory ?? []

        return directories.compactMap { dto in
            guard let kind = dto.kind else { return nil }  // skip music, photos for 0.2
            return Library(
                id: .init(source: id, rawValue: dto.key),
                title: dto.title,
                kind: kind
            )
        }
    }

    public func items(in libraryID: Library.ID) async throws -> [MediaItem] {
        let base = try await resolveBaseURL()
        let request = request(base: base, path: "/library/sections/\(libraryID.rawValue)/all")
        let response = try await api.decode(
            PlexAPI.LibraryItemsResponse.self,
            from: request,
            decoder: decoder
        )
        let metadata = response.mediaContainer.metadata ?? []
        return metadata.map { mapMetadataToMediaItem($0, base: base) }
    }

    // MARK: - Connection resolution + failover

    /// Return a reachable connection's base URL, probing `/identity` in ranked
    /// order. The first success is cached for the rest of the session.
    /// Throws `PlexConnectionError.noReachableConnection` when every candidate
    /// fails (e.g. server offline, or off-network with no remote connection).
    func resolveBaseURL() async throws -> URL {
        if let resolvedBaseURL { return resolvedBaseURL }

        for connection in connections {
            guard let base = connection.url else { continue }
            if await isReachable(base) {
                resolvedBaseURL = base
                return base
            }
        }
        throw PlexConnectionError.noReachableConnection
    }

    /// Forget the cached connection — call when a request later fails so the
    /// next request re-probes (e.g. the user moved from LAN to cellular while
    /// the app was backgrounded).
    public func invalidateConnection() {
        resolvedBaseURL = nil
    }

    private func isReachable(_ base: URL) async -> Bool {
        var request = request(base: base, path: "/identity")
        request.timeoutInterval = probeTimeout
        do {
            let (_, response) = try await api.data(for: request)
            return (200..<300).contains(response.statusCode)
        } catch {
            return false
        }
    }

    // MARK: - Mapping

    /// Translate one Plex `Metadata` into Aether's source-agnostic `MediaItem`.
    ///
    /// - Plex runtimes are in **milliseconds**; we convert to seconds.
    /// - Poster / backdrop / stream URLs are built against the resolved base
    ///   URL and tokenised via a query parameter so plain `AsyncImage` /
    ///   `AVPlayer` work without setting headers.
    /// - `streamURL` is the **direct-play** URL (first Part's path). Present
    ///   for movies + episodes; `nil` for containers (shows, seasons).
    nonisolated func mapMetadataToMediaItem(_ dto: PlexAPI.Metadata, base: URL) -> MediaItem {
        MediaItem(
            id: .init(source: id, rawValue: dto.ratingKey),
            title: dto.title,
            kind: dto.kind,
            year: dto.year,
            runtime: dto.duration.map { .seconds(Double($0) / 1000.0) },
            summary: dto.summary,
            posterURL: tokenisedURL(base: base, path: dto.thumb),
            backdropURL: tokenisedURL(base: base, path: dto.art),
            streamURL: tokenisedURL(base: base, path: dto.firstPartKey)
        )
    }

    // MARK: - URL helpers

    /// Build a PMS request against a resolved base URL, attaching the server's
    /// common headers + `X-Plex-Token`.
    nonisolated func request(base: URL, path: String, queryItems: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(
            url: base.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        var request = URLRequest(url: components.url!)
        for (key, value) in configuration.commonHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue(accessToken, forHTTPHeaderField: "X-Plex-Token")
        return request
    }

    /// Turn a Plex relative path into a tokenised absolute URL against `base`.
    /// `X-Plex-Token` goes in the query because `AsyncImage` / `AVPlayer` can't
    /// set headers; Plex accepts the token in either position.
    nonisolated func tokenisedURL(base: URL, path relativePath: String?) -> URL? {
        guard let relativePath, !relativePath.isEmpty else { return nil }
        let combined = base.appendingPathComponent(relativePath)
        guard var components = URLComponents(url: combined, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var query = components.queryItems ?? []
        query.append(URLQueryItem(name: "X-Plex-Token", value: accessToken))
        components.queryItems = query
        return components.url
    }
}

public enum PlexConnectionError: Error, Sendable, Equatable {
    case noReachableConnection
}
