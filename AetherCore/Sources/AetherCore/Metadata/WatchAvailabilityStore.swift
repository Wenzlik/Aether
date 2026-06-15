import Foundation

/// `@MainActor`-bound mirror of Netflix availability for SwiftUI views (#360),
/// modelled on `DownloadObserver`: a card reads `availability.netflix(forTMDb:)`
/// **synchronously** in `body` (no actor hop, no `await` in the render path).
///
/// On a miss it returns `nil` and kicks off a cached, deduplicated background
/// lookup; when that resolves it writes back, and `@Observable` re-renders the
/// card with the badge. A storm of identical poster lookups collapses to one
/// network call (the in-flight set + the service's own 24h cache).
///
/// Lives in AetherCore so every app target (iOS/tvOS/visionOS and macOS) shares
/// one implementation; each target builds it with its own TMDb key + region via
/// the `makeService` closure.
@Observable
@MainActor
public final class WatchAvailabilityStore {
    private let preferences: StreamingPreferencesStore
    /// Rebuilds a service with the current TMDb key + resolved region. Returns
    /// nil when TMDb isn't configured (no key) — then availability is simply off.
    private let makeService: @MainActor () -> WatchProvidersService?

    /// Resolved Netflix hits, keyed `"<tmdbID>.<isShow>"`.
    private var netflixHits: [String: ExternalProvider] = [:]
    /// Keys we've already resolved (hit *or* miss), so we don't re-query a title
    /// that simply isn't on Netflix.
    private var resolved: Set<String> = []
    /// Lookups currently in flight, so concurrent cells don't each fire one.
    private var inFlight: Set<String> = []

    public init(preferences: StreamingPreferencesStore, makeService: @escaping @MainActor () -> WatchProvidersService?) {
        self.preferences = preferences
        self.makeService = makeService
    }

    /// Whether the feature is on at all — gates every badge / rail / action.
    public var isEnabled: Bool { preferences.netflixAvailabilityEnabled }

    /// The Netflix provider for an owned title, or nil if it isn't on Netflix
    /// (or we haven't looked yet — the lookup is fired in the background).
    /// `tmdbID` is the title's `guids.tmdb`; `isShow` picks the TMDb media type.
    public func netflix(forTMDb tmdbID: String?, isShow: Bool) -> ExternalProvider? {
        guard isEnabled, let tmdbID, let id = Int(tmdbID) else { return nil }
        let key = "\(id).\(isShow)"
        if let hit = netflixHits[key] { return hit }
        if resolved.contains(key) { return nil }
        lookUp(id: id, isShow: isShow, key: key)
        return nil
    }

    /// Convenience for card call sites: the Netflix logo URL to badge a unified
    /// title with, or nil. An external-only title is *itself* a Netflix result,
    /// so it's never re-badged (the poster already represents Netflix).
    public func netflixLogoURL(for item: UnifiedMediaItem) -> URL? {
        guard !item.isExternalOnly else { return nil }
        return netflix(forTMDb: item.tmdbID, isShow: item.isShow)?.logoURL
    }

    /// Same, for a raw per-source `MediaItem` (Detail, episode rails).
    public func netflixLogoURL(for item: MediaItem) -> URL? {
        if case .external = item.id.source { return nil }
        return netflix(forTMDb: item.guids.tmdb, isShow: item.kind == .show)?.logoURL
    }

    /// Whether **Netflix-only** posters should appear in Discover / Search — the
    /// feature is on *and* the user hasn't opted to keep those screens to what
    /// they own.
    public var showsNetflixOnly: Bool { isEnabled && preferences.showNetflixOnlyTitles }

    /// Netflix-only titles for a Discover rail (#360), already wrapped as
    /// external `UnifiedMediaItem`s. The caller dedupes against owned titles.
    public func netflixOnlyDiscover(isShow: Bool, sort: TMDbClient.DiscoverSort) async -> [UnifiedMediaItem] {
        guard showsNetflixOnly, let service = makeService(), service.isConfigured else { return [] }
        let metas = await service.netflixTitles(type: isShow ? .tv : .movie, sort: sort)
        return metas.map { UnifiedMediaItem.externalNetflix(from: $0, isShow: isShow) }
    }

    /// Netflix-only matches for a Search query, as external `UnifiedMediaItem`s.
    public func netflixOnlySearch(_ query: String) async -> [UnifiedMediaItem] {
        guard showsNetflixOnly, let service = makeService(), service.isConfigured else { return [] }
        let matches = await service.netflixSearch(title: query)
        return matches.map { UnifiedMediaItem.externalNetflix(from: $0.meta, isShow: $0.isShow) }
    }

    /// Drop everything so the toggle / region change re-resolves from scratch.
    public func invalidate() {
        netflixHits.removeAll()
        resolved.removeAll()
        inFlight.removeAll()
    }

    private func lookUp(id: Int, isShow: Bool, key: String) {
        guard !inFlight.contains(key), let service = makeService(), service.isConfigured else { return }
        inFlight.insert(key)
        Task { @MainActor in
            let provider = await service.netflix(forTMDb: id, type: isShow ? .tv : .movie)
            inFlight.remove(key)
            resolved.insert(key)
            if let provider { netflixHits[key] = provider }
        }
    }
}
