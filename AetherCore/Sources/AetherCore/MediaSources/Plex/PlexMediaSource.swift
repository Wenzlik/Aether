import Foundation

/// A Plex Media Server connection wired up as an Aether `MediaSource`.
///
/// Holds the configuration, the auth token, the chosen connection (base URL),
/// and an `APIClient`. Implements:
/// - `libraries()` → `GET /library/sections`
/// - `items(in:)`  → `GET /library/sections/{key}/all`
///
/// Stream URL resolution and playback land in the next PR.
public actor PlexMediaSource: MediaSource {
    public let id: MediaSourceID
    public let displayName: String

    private let api: any APIClient
    private let configuration: PlexConfiguration
    private let baseURL: URL
    private let accessToken: String
    private let decoder: JSONDecoder

    public init(
        serverID: String,
        displayName: String,
        baseURL: URL,
        accessToken: String,
        configuration: PlexConfiguration,
        api: any APIClient
    ) {
        self.id = .plex(serverID: serverID)
        self.displayName = displayName
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.configuration = configuration
        self.api = api
        self.decoder = JSONDecoder()
    }

    // MARK: - MediaSource

    public func libraries() async throws -> [Library] {
        let request = request(forPath: "/library/sections")
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
        let request = request(forPath: "/library/sections/\(libraryID.rawValue)/all")
        let response = try await api.decode(
            PlexAPI.LibraryItemsResponse.self,
            from: request,
            decoder: decoder
        )
        let metadata = response.mediaContainer.metadata ?? []
        return metadata.map(mapMetadataToMediaItem)
    }

    // MARK: - Mapping

    /// Translate one Plex `Metadata` into Aether's source-agnostic `MediaItem`.
    ///
    /// - Plex runtimes are in **milliseconds**; we convert to seconds.
    /// - Poster / backdrop URLs are constructed against the server's base URL
    ///   and tokenised via a query parameter so plain `AsyncImage` works
    ///   without setting headers (see `tokenisedURL(for:)`).
    /// - `streamURL` is `nil` in 0.2 — playback wires in the next PR.
    nonisolated func mapMetadataToMediaItem(_ dto: PlexAPI.Metadata) -> MediaItem {
        MediaItem(
            id: .init(source: id, rawValue: dto.ratingKey),
            title: dto.title,
            kind: dto.kind,
            year: dto.year,
            runtime: dto.duration.map { .seconds(Double($0) / 1000.0) },
            summary: dto.summary,
            posterURL: tokenisedURL(for: dto.thumb),
            backdropURL: tokenisedURL(for: dto.art),
            streamURL: nil
        )
    }

    // MARK: - URL helpers

    /// Build a PMS request URL for a relative path, attaching the server's
    /// common headers + `X-Plex-Token`. Used by the endpoint calls above and
    /// available to future endpoint code.
    nonisolated func request(forPath path: String, queryItems: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
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

    /// Turn a Plex relative path (e.g. `/library/metadata/123/thumb/...`) into
    /// a tokenised absolute URL.
    ///
    /// We embed `X-Plex-Token` as a **query parameter** rather than a header
    /// because the artwork is fetched by `AsyncImage`, which can't set
    /// headers. Plex accepts the token in either position.
    nonisolated func tokenisedURL(for relativePath: String?) -> URL? {
        guard let relativePath, !relativePath.isEmpty else { return nil }

        // `appendingPathComponent` percent-encodes path segments correctly even
        // for paths that contain slashes; `URLComponents` then carries the
        // query through cleanly.
        let combined = baseURL.appendingPathComponent(relativePath)
        guard var components = URLComponents(url: combined, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var query = components.queryItems ?? []
        query.append(URLQueryItem(name: "X-Plex-Token", value: accessToken))
        components.queryItems = query
        return components.url
    }
}
