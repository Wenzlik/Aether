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
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let response = try? await api.decode(SearchResponse.self, from: request, decoder: decoder),
              let first = response.results.first else {
            return nil
        }
        let name = first.title ?? first.name ?? title
        let date = first.releaseDate ?? first.firstAirDate
        let matchedYear = date.flatMap { Int($0.prefix(4)) } ?? year
        return TMDbMetadata(
            tmdbID: first.id,
            title: name,
            year: matchedYear,
            overview: first.overview?.nonEmptyTrimmed,
            posterURL: Self.imageURL(first.posterPath, size: "w500"),
            backdropURL: Self.imageURL(first.backdropPath, size: "w1280")
        )
    }

    // MARK: - Request

    private func searchRequest(title: String, year: Int?, isEpisode: Bool) -> URLRequest? {
        let path = isEpisode ? "/search/tv" : "/search/movie"
        var components = URLComponents(
            url: Self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false
        )
        var items = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "query", value: title),
            URLQueryItem(name: "include_adult", value: "false")
        ]
        if let year {
            items.append(URLQueryItem(name: isEpisode ? "first_air_date_year" : "year", value: String(year)))
        }
        components?.queryItems = items
        guard let url = components?.url else { return nil }
        return URLRequest(url: url)
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
