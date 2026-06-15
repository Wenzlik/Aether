import Foundation
import os

/// The availability layer over TMDb Watch Providers (#360). Answers two
/// questions, both cached so a screen full of posters doesn't storm the network:
///
/// - **"Is this owned title on Netflix here?"** — `providers(forTMDb:type:region:)`,
///   cached per `tmdbID + region` with a 24h TTL (availability changes weekly,
///   not by the minute).
/// - **"What's on Netflix to discover?"** — `netflixTitles(type:region:sort:)`,
///   cached per `region + type + sort` for the Discover rails.
///
/// This is an *availability* source, not a playback `MediaSource`: it never
/// resolves a stream. Best-effort throughout — every miss returns empty, leaving
/// the UI to simply not show a badge / rail.
public struct WatchProvidersService: Sendable {
    private let client: TMDbClient
    private let cache: Cache
    private let region: String

    private static let log = Logger(subsystem: "cz.zmrhal.aether", category: "watch.providers")

    /// - Parameter region: ISO-3166 country code (`"US"`, `"CZ"`, …). The caller
    ///   resolves it from the user's Settings region / app locale.
    public init(apiKey: String, api: any APIClient, region: String, cache: Cache = Cache()) {
        self.client = TMDbClient(apiKey: apiKey, api: api)
        self.cache = cache
        self.region = region.uppercased()
    }

    public var isConfigured: Bool { client.isConfigured }

    /// Providers an owned title is available on, cached. `type` follows the
    /// title's kind (show → `.tv`, else `.movie`).
    public func providers(forTMDb tmdbID: Int, type: TMDbClient.MediaType) async -> [ExternalProvider] {
        let key = "\(tmdbID).\(region).\(type.path)"
        if let hit = await cache.providers(key) { return hit }
        let fresh = await client.watchProviders(forTMDb: tmdbID, type: type, region: region)
        await cache.setProviders(fresh, key)
        return fresh
    }

    /// Whether an owned title is on Netflix in the configured region — the badge
    /// signal. Returns the `ExternalProvider` (so callers get its logo URL) or nil.
    public func netflix(forTMDb tmdbID: Int, type: TMDbClient.MediaType) async -> ExternalProvider? {
        await providers(forTMDb: tmdbID, type: type).first(where: \.isNetflix)
    }

    /// Netflix titles for a Discover rail (deduped/owned-filtered by the caller),
    /// cached per region + type + sort.
    public func netflixTitles(
        type: TMDbClient.MediaType,
        sort: TMDbClient.DiscoverSort
    ) async -> [TMDbMetadata] {
        let key = "discover.\(ExternalProvider.netflixID).\(region).\(type.path).\(sort.rawValue)"
        if let hit = await cache.titles(key) { return hit }
        let fresh = await client.discover(
            provider: ExternalProvider.netflixID, type: type, region: region, sortBy: sort
        )
        Self.log.debug("Netflix discover \(type.path, privacy: .public)/\(sort.rawValue, privacy: .public): \(fresh.count) titles")
        await cache.setTitles(fresh, key)
        return fresh
    }

    /// Netflix-only matches for a free-text query (#360 unified Search): search
    /// TMDb (movies + shows), then keep only the candidates that are on Netflix
    /// in the configured region. Provider checks run concurrently and are cached.
    /// Returns `(metadata, isShow)` pairs so the caller can build the right kind.
    public func netflixSearch(title: String, limit: Int = 6) async -> [(meta: TMDbMetadata, isShow: Bool)] {
        guard isConfigured else { return [] }
        async let movies = client.searchCandidates(title: title, year: nil, isEpisode: false, limit: limit)
        async let shows = client.searchCandidates(title: title, year: nil, isEpisode: true, limit: limit)
        let candidates = (await movies).map { ($0, false) } + (await shows).map { ($0, true) }

        return await withTaskGroup(of: (TMDbMetadata, Bool)?.self) { group in
            for (meta, isShow) in candidates {
                group.addTask {
                    let onNetflix = await self.netflix(forTMDb: meta.tmdbID, type: isShow ? .tv : .movie) != nil
                    return onNetflix ? (meta, isShow) : nil
                }
            }
            var out: [(meta: TMDbMetadata, isShow: Bool)] = []
            for await result in group {
                if let result { out.append((meta: result.0, isShow: result.1)) }
            }
            return out
        }
    }

    // MARK: - Cache

    /// 24h-TTL in-memory cache for provider lookups + discover rails. Small JSON,
    /// so memory-only (no disk) — far simpler than `AetherImageCache`. An actor
    /// so it's safe to share across the concurrent per-poster lookups.
    public actor Cache {
        private struct Entry<T: Sendable>: Sendable { let value: T; let at: Date }
        private var providersByKey: [String: Entry<[ExternalProvider]>] = [:]
        private var titlesByKey: [String: Entry<[TMDbMetadata]>] = [:]
        private let ttl: TimeInterval
        private let now: @Sendable () -> Date

        /// - Parameter now: injectable clock for tests; defaults to `Date()`.
        public init(ttl: TimeInterval = 24 * 3600, now: @escaping @Sendable () -> Date = { Date() }) {
            self.ttl = ttl
            self.now = now
        }

        func providers(_ key: String) -> [ExternalProvider]? { fresh(providersByKey[key]) }
        func titles(_ key: String) -> [TMDbMetadata]? { fresh(titlesByKey[key]) }
        func setProviders(_ value: [ExternalProvider], _ key: String) { providersByKey[key] = Entry(value: value, at: now()) }
        func setTitles(_ value: [TMDbMetadata], _ key: String) { titlesByKey[key] = Entry(value: value, at: now()) }

        private func fresh<T>(_ entry: Entry<T>?) -> T? {
            guard let entry, now().timeIntervalSince(entry.at) < ttl else { return nil }
            return entry.value
        }
    }
}
