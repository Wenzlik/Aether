import Foundation

/// Resolved TMDb metadata for a local title — poster/backdrop, overview, the
/// canonical title + year. Stored on a `LocalLibraryStore.Item` so the Local
/// Library can show real artwork instead of a filename. Codable (persisted).
public struct TMDbMetadata: Sendable, Equatable, Hashable, Codable {
    public let tmdbID: Int
    public let title: String
    public let year: Int?
    public let overview: String?
    public let posterURL: URL?
    public let backdropURL: URL?

    public init(tmdbID: Int, title: String, year: Int?, overview: String?, posterURL: URL?, backdropURL: URL?) {
        self.tmdbID = tmdbID
        self.title = title
        self.year = year
        self.overview = overview
        self.posterURL = posterURL
        self.backdropURL = backdropURL
    }
}

/// Looks up metadata for filename-inferred titles via The Movie Database (TMDb)
/// v3 search. Used to enrich the Local Library (#210) — files have no metadata
/// API of their own. The API key is the user's, held in the Keychain and passed
/// in here; an empty key disables matching (the feature is opt-in by key).
///
/// Best-effort + non-throwing: any failure (no key, network, no result) returns
/// `nil`, leaving the inferred title in place. Goes through `APIClient`, so it's
/// unit-tested with a fake.
public struct TMDbClient: Sendable {
    private let apiKey: String
    private let api: any APIClient
    private static let base = URL(string: "https://api.themoviedb.org/3")!
    private static let imageBase = "https://image.tmdb.org/t/p/"

    public init(apiKey: String, api: any APIClient) {
        self.apiKey = apiKey
        self.api = api
    }

    /// Whether a non-empty key was supplied (matching is possible).
    public var isConfigured: Bool { !apiKey.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Best match for a title — searches TV when `isEpisode`, else movies. Picks
    /// the first (most-relevant) result. `nil` on any failure.
    public func match(title: String, year: Int?, isEpisode: Bool) async -> TMDbMetadata? {
        guard isConfigured, let request = searchRequest(title: title, year: year, isEpisode: isEpisode) else {
            return nil
        }
        guard let first = await search(title: title, year: year, isEpisode: isEpisode, request: request).first else {
            return nil
        }
        return first
    }

    /// Top matches for a title, so the user can pick the right one when the best
    /// guess is wrong (#211). Returns up to `limit` candidates, most-relevant
    /// first; empty on any failure. Searches TV when `isEpisode`, else movies.
    public func searchCandidates(title: String, year: Int?, isEpisode: Bool, limit: Int = 6) async -> [TMDbMetadata] {
        guard isConfigured, let request = searchRequest(title: title, year: year, isEpisode: isEpisode) else {
            return []
        }
        return Array(await search(title: title, year: year, isEpisode: isEpisode, request: request).prefix(limit))
    }

    /// Decode a search response and map every result to `TMDbMetadata`.
    private func search(title: String, year: Int?, isEpisode: Bool, request: URLRequest) async -> [TMDbMetadata] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let response = try? await api.decode(SearchResponse.self, from: request, decoder: decoder) else {
            return []
        }
        return response.results.map { result in
            let name = result.title ?? result.name ?? title
            let date = result.releaseDate ?? result.firstAirDate
            let matchedYear = date.flatMap { Int($0.prefix(4)) } ?? year
            return TMDbMetadata(
                tmdbID: result.id,
                title: name,
                year: matchedYear,
                overview: result.overview?.nonEmptyTrimmed,
                posterURL: Self.imageURL(result.posterPath, size: "w500"),
                backdropURL: Self.imageURL(result.backdropPath, size: "w1280")
            )
        }
    }

    // MARK: - Request

    /// A TMDb **v4** Read Access Token (JWT, `eyJ…`) authenticates via an
    /// `Authorization: Bearer` header on the v3 REST endpoints; a classic **v3**
    /// API key goes in the `api_key` query param. Support both so either kind of
    /// credential works.
    private var usesBearerToken: Bool { apiKey.hasPrefix("eyJ") }

    private func searchRequest(title: String, year: Int?, isEpisode: Bool) -> URLRequest? {
        let path = isEpisode ? "/search/tv" : "/search/movie"
        var components = URLComponents(
            url: Self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false
        )
        var items = [
            URLQueryItem(name: "query", value: title),
            URLQueryItem(name: "include_adult", value: "false")
        ]
        if !usesBearerToken {
            items.insert(URLQueryItem(name: "api_key", value: apiKey), at: 0)
        }
        if let year {
            items.append(URLQueryItem(name: isEpisode ? "first_air_date_year" : "year", value: String(year)))
        }
        components?.queryItems = items
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        if usesBearerToken {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "accept")
        }
        return request
    }

    static func imageURL(_ path: String?, size: String) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: imageBase + size + path)
    }

    // MARK: - DTOs

    private struct SearchResponse: Decodable, Sendable {
        let results: [Result]
    }

    private struct Result: Decodable, Sendable {
        let id: Int
        let title: String?        // movies
        let name: String?         // TV
        let releaseDate: String?  // movies, "YYYY-MM-DD"
        let firstAirDate: String? // TV
        let overview: String?
        let posterPath: String?
        let backdropPath: String?
    }
}
