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
    /// TMDb `vote_average` (0–10), or `nil` when the result didn't carry one.
    public let rating: Double?

    public init(tmdbID: Int, title: String, year: Int?, overview: String?, posterURL: URL?, backdropURL: URL?, rating: Double? = nil) {
        self.tmdbID = tmdbID
        self.title = title
        self.year = year
        self.overview = overview
        self.posterURL = posterURL
        self.backdropURL = backdropURL
        self.rating = rating
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

    /// Outcome of checking a token against TMDb (#214 token validation).
    public enum ValidationResult: Sendable, Equatable {
        case empty          // nothing entered
        case valid          // TMDb accepted it
        case invalid        // TMDb rejected it (401 / 403) — wrong key
        case networkError   // couldn't reach TMDb — can't tell either way
    }

    /// Verify the token with a real TMDb call. Uses `/authentication`, which
    /// requires a valid credential and returns 200 regardless of library content
    /// — so it's a clean key check independent of any title. Works for both a v3
    /// api_key and a v4 bearer token.
    public func validate() async -> ValidationResult {
        guard isConfigured, let request = authenticationRequest() else { return .empty }
        do {
            let (_, response) = try await api.data(for: request)
            switch response.statusCode {
            case 200...299: return .valid
            case 401, 403:  return .invalid
            default:        return .networkError
            }
        } catch {
            return .networkError
        }
    }

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
                backdropURL: Self.imageURL(result.backdropPath, size: "w1280"),
                rating: result.voteAverage
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

    /// `GET /authentication` with the credential attached the same way as a
    /// search request — for `validate()`.
    private func authenticationRequest() -> URLRequest? {
        var components = URLComponents(
            url: Self.base.appendingPathComponent("/authentication"), resolvingAgainstBaseURL: false
        )
        if !usesBearerToken {
            components?.queryItems = [URLQueryItem(name: "api_key", value: apiKey)]
        }
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

    // MARK: - Detail by ID

    /// Fetch title details directly by TMDb ID — used to get `vote_average` for
    /// Plex / Jellyfin items that already carry a `guids.tmdb` ID but whose
    /// server metadata didn't supply a TMDb rating. Best-effort + non-throwing:
    /// `nil` on any failure (no key, network, no result).
    public func details(tmdbID: Int, type: MediaType) async -> TMDbMetadata? {
        guard isConfigured, let request = simpleRequest(path: "/\(type.path)/\(tmdbID)") else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let result = try? await api.decode(DetailsResponse.self, from: request, decoder: decoder) else {
            return nil
        }
        let date = result.releaseDate ?? result.firstAirDate
        return TMDbMetadata(
            tmdbID: tmdbID,
            title: result.title ?? result.name ?? "",
            year: date.flatMap { Int($0.prefix(4)) },
            overview: result.overview?.nonEmptyTrimmed,
            posterURL: Self.imageURL(result.posterPath, size: "w500"),
            backdropURL: Self.imageURL(result.backdropPath, size: "w1280"),
            rating: result.voteAverage
        )
    }

    // MARK: - Watch providers + discovery (#360)

    /// Whether a title is a movie or a TV show, for the path segment TMDb uses.
    public enum MediaType: Sendable {
        case movie, tv
        var path: String { self == .tv ? "tv" : "movie" }
    }

    /// Sort order for `discover` rails (#360 — "New on Netflix" vs "Top on
    /// Netflix"). Raw values are TMDb `sort_by` values.
    public enum DiscoverSort: String, Sendable {
        case newest = "primary_release_date.desc"
        case topRated = "vote_average.desc"
        case popular = "popularity.desc"
    }

    /// Streaming providers a title is available on in `region`, from
    /// `GET /{movie|tv}/{id}/watch/providers` → `results[region].flatrate`.
    /// Best-effort + non-throwing: empty on any failure (no key, network, no
    /// result), mirroring the rest of the client.
    public func watchProviders(forTMDb tmdbID: Int, type: MediaType, region: String) async -> [ExternalProvider] {
        guard isConfigured, let request = simpleRequest(path: "/\(type.path)/\(tmdbID)/watch/providers") else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let response = try? await api.decode(WatchProvidersResponse.self, from: request, decoder: decoder) else {
            return []
        }
        // `flatrate` = subscription (what Netflix is); ignore rent / buy.
        let entry = response.results[region.uppercased()]
        return (entry?.flatrate ?? []).map {
            ExternalProvider(
                id: $0.providerId,
                name: $0.providerName,
                logoURL: Self.imageURL($0.logoPath, size: "w92")
            )
        }
    }

    /// Titles available on `provider` in `region`, from
    /// `GET /discover/{movie|tv}?with_watch_providers=…&watch_region=…`. Used
    /// for the "New on Netflix" / "Top on Netflix" Discover rails. Empty on any
    /// failure.
    public func discover(
        provider: Int,
        type: MediaType,
        region: String,
        sortBy: DiscoverSort = .popular,
        page: Int = 1
    ) async -> [TMDbMetadata] {
        let extra = [
            URLQueryItem(name: "with_watch_providers", value: String(provider)),
            URLQueryItem(name: "watch_region", value: region.uppercased()),
            URLQueryItem(name: "with_watch_monetization_types", value: "flatrate"),
            URLQueryItem(name: "sort_by", value: sortBy.rawValue),
            URLQueryItem(name: "include_adult", value: "false"),
            URLQueryItem(name: "vote_count.gte", value: "100"),
            URLQueryItem(name: "page", value: String(page))
        ]
        guard isConfigured, let request = simpleRequest(path: "/discover/\(type.path)", extraQuery: extra) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let response = try? await api.decode(SearchResponse.self, from: request, decoder: decoder) else {
            return []
        }
        return response.results.map { result in
            let name = result.title ?? result.name ?? ""
            let date = result.releaseDate ?? result.firstAirDate
            let year = date.flatMap { Int($0.prefix(4)) }
            return TMDbMetadata(
                tmdbID: result.id,
                title: name,
                year: year,
                overview: result.overview?.nonEmptyTrimmed,
                posterURL: Self.imageURL(result.posterPath, size: "w500"),
                backdropURL: Self.imageURL(result.backdropPath, size: "w1280"),
                rating: result.voteAverage
            )
        }
    }

    /// A bare GET request to `path` with the credential attached the same way as
    /// a search request (api_key query param, or a v4 bearer header), plus any
    /// `extraQuery` items (used by the discover endpoint).
    private func simpleRequest(path: String, extraQuery: [URLQueryItem] = []) -> URLRequest? {
        var components = URLComponents(
            url: Self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false
        )
        var items = extraQuery
        if !usesBearerToken {
            items.insert(URLQueryItem(name: "api_key", value: apiKey), at: 0)
        }
        components?.queryItems = items.isEmpty ? nil : items
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        if usesBearerToken {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "accept")
        }
        return request
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
        let voteAverage: Double?
    }

    /// `/movie/{id}` or `/tv/{id}` response — same shape as a search result but
    /// fetched directly by known TMDb id, so we can pick up `vote_average` for
    /// Plex / Jellyfin items without searching by title.
    private struct DetailsResponse: Decodable, Sendable {
        let title: String?
        let name: String?
        let releaseDate: String?
        let firstAirDate: String?
        let overview: String?
        let posterPath: String?
        let backdropPath: String?
        let voteAverage: Double?
    }

    /// `/watch/providers` response: per-region buckets of provider lists.
    private struct WatchProvidersResponse: Decodable, Sendable {
        let results: [String: RegionProviders]
    }

    private struct RegionProviders: Decodable, Sendable {
        let flatrate: [Provider]?
    }

    private struct Provider: Decodable, Sendable {
        // `.convertFromSnakeCase` maps `provider_id` → `providerId` (lowercase d),
        // so the property must match exactly — `providerID` silently fails to
        // decode and drops every provider.
        let providerId: Int
        let providerName: String
        let logoPath: String?
    }
}
