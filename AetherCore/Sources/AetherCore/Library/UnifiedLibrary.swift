import Foundation

/// Unified Library: fans out across every connected source, fetches its items,
/// and merges them into deduplicated `UnifiedMediaItem`s with offline copies
/// surfaced as a source.
///
/// The pure merge logic (`merge(...)`, Phase 1b) is `nonisolated static` and
/// fully unit-tested; the actor adds the fault-tolerant fan-out (Phase 2) that
/// the views consume. The single hard part — identity + merging — stays
/// isolated and testable.
///
/// **Deduplication** is union-find over shared external IDs: two items merge if
/// they share *any* of TMDB / IMDB / TVDB (so a Plex item with TMDB+IMDB merges
/// with a Jellyfin item that only exposes IMDB). Items with no external ID fall
/// back to normalised title + year, and merge only with others that match
/// exactly — conservative, to avoid false merges. Items with neither never
/// merge (one row per source).
public actor UnifiedLibrary {
    private let sources: [any MediaSource]
    private let downloads: DownloadStore?
    private let snapshotStore: UnifiedLibrarySnapshotStore

    /// A persisted snapshot older than this is still served instantly on a cold
    /// launch, but the view is told to refresh it in the background (issue #197).
    /// Distinct from `UnifiedLibraryCache`'s 45 s in-session reuse TTL.
    public static let snapshotStaleness: TimeInterval = 3600   // 1 hour

    public init(
        sources: [any MediaSource],
        downloads: DownloadStore? = nil,
        snapshotStore: UnifiedLibrarySnapshotStore = .shared
    ) {
        self.sources = sources
        self.downloads = downloads
        self.snapshotStore = snapshotStore
    }

    /// Server display names keyed by source id, derived from the sources
    /// themselves (for the unified "Available Sources" rows).
    private var serverNames: [MediaSourceID: String] {
        Dictionary(sources.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    }

    /// All unified titles of `kind` across connected sources. Fault-tolerant: a
    /// source that fails to list libraries or items is skipped, not fatal, so a
    /// slow/down server never blanks the feed.
    public func unifiedItems(kind: MediaItem.Kind, forceRefresh: Bool = false) async -> [UnifiedMediaItem] {
        // Serve a recent result if one exists — Home, Library, Discover, Search
        // and the grid all build from this, so without a cache every tab switch /
        // appearance re-hits every server and re-runs the dedup. The cache is
        // process-shared (call sites make their own `UnifiedLibrary`), keyed by
        // the connected-source set, short-TTL. Pull-to-refresh passes
        // `forceRefresh` to bypass it and re-stamp the cache.
        let key = cacheKey(kind: kind)
        if !forceRefresh {
            // An *empty* cached/snapshot value is treated as a miss, never served.
            // A transient empty fan-out (a server not yet ready at launch, or a
            // momentary hiccup) must not be able to pin an empty catalog under
            // this source-set key and have it served at any age — that's exactly
            // what stranded the "See all" grid (and Discover) on "Nothing here
            // yet" once the Local Library flipped the connected-source set, while
            // the rails kept showing their last-good state (#263). Ignoring empty
            // here also self-heals any empty already persisted by an older build.
            if let cached = await UnifiedLibraryCache.shared.items(for: key), !cached.isEmpty {
                return cached
            }
            // Cold in-memory cache (e.g. a fresh launch): serve the persisted
            // snapshot instantly — any age, no network — so the library never
            // flashes a loading state when we already know what was there. The
            // caller refreshes in the background when `isStale(kind:)` is true.
            // Only a first-ever launch with no snapshot falls through to the
            // blocking fan-out below (the sole place a loading state appears).
            if let snapshot = await snapshotStore.snapshot(for: key), !snapshot.items.isEmpty {
                await UnifiedLibraryCache.shared.set(snapshot.items, for: key)
                return snapshot.items
            }
        }
        // Fan out across sources concurrently (and each source's libraries
        // concurrently) instead of serially — the serial version made Home /
        // Library wait for the slowest server's last library before first paint.
        async let downloadedTask = downloadedIDs()
        let items = await withTaskGroup(of: [MediaItem].self) { group in
            for source in sources {
                group.addTask {
                    guard let libraries = try? await source.libraries() else { return [] }
                    return await withTaskGroup(of: [MediaItem].self) { inner in
                        for library in libraries where library.kind == kind {
                            inner.addTask { (try? await source.items(in: library.id)) ?? [] }
                        }
                        var acc: [MediaItem] = []
                        for await chunk in inner { acc += chunk }
                        return acc
                    }
                }
            }
            var all: [MediaItem] = []
            for await chunk in group { all += chunk }
            return all
        }
        let downloaded = await downloadedTask
        let merged = Self.merge(items, downloaded: downloaded, serverNames: serverNames)
        // Never cache or persist an empty result. The fan-out is fault-tolerant
        // (a failing/slow source contributes nothing), so an empty merge means
        // "we couldn't see anything *right now*", not "this catalog is empty" —
        // pinning it would strand every surface that reads this key until the TTL
        // expired or a manual refresh, even though the next fetch would succeed
        // (#263). Returning empty without caching lets the very next appearance
        // self-heal via a fresh fan-out.
        if !merged.isEmpty {
            await UnifiedLibraryCache.shared.set(merged, for: key)
            // Re-stamp the cross-launch snapshot with the fresh catalog so the
            // next cold start paints it instantly.
            await snapshotStore.save(merged, for: key, at: Date())
        }
        return merged
    }

    // MARK: - Audio-language filter (#295)

    /// Available audio languages across connected sources for `kind`, as
    /// display-ready options. Server-filterable sources (Plex) contribute their
    /// own filter values; everything else is read off the loaded catalog's audio
    /// tracks (Jellyfin carries them in its list responses). Deduped + sorted.
    public func audioLanguageOptions(kind: MediaItem.Kind, locale: Locale = .current) async -> [AudioLanguageOption] {
        // (a) Server-side filter values (Plex `/audioLanguage`).
        let serverCodes = await withTaskGroup(of: [String].self) { group in
            for source in sources where source.supportsAudioLanguageFilter {
                group.addTask {
                    guard let libraries = try? await source.libraries() else { return [] }
                    return await withTaskGroup(of: [String].self) { inner in
                        for library in libraries where library.kind == kind {
                            inner.addTask { await source.audioLanguageOptions(in: library.id) }
                        }
                        var acc: [String] = []
                        for await chunk in inner { acc += chunk }
                        return acc
                    }
                }
            }
            var all: [String] = []
            for await chunk in group { all += chunk }
            return all
        }

        // (b) Languages carried in the loaded catalog's audio tracks. Plex grid
        // items have none (its list omits streams) → they contribute nothing
        // here and rely on (a); Jellyfin items carry theirs.
        var rawCodes: [String?] = serverCodes.map { $0 }
        for item in await unifiedItems(kind: kind) {
            for source in item.sources {
                rawCodes += source.item.audioTracks.map(\.languageCode)
            }
        }
        return AudioLanguage.options(fromRawCodes: rawCodes, locale: locale)
    }

    /// Unified titles of `kind` whose audio is available in `audioLanguage`
    /// (#295). Sources that filter server-side (Plex) re-query with the code;
    /// the rest load normally and are filtered client-side from their audio
    /// tracks. Not cached — filtering is an explicit, transient user action.
    public func unifiedItems(kind: MediaItem.Kind, audioLanguage: String?) async -> [UnifiedMediaItem] {
        guard let audioLanguage else { return await unifiedItems(kind: kind) }
        async let downloadedTask = downloadedIDs()
        let items = await withTaskGroup(of: [MediaItem].self) { group in
            for source in sources {
                group.addTask {
                    guard let libraries = try? await source.libraries() else { return [] }
                    return await withTaskGroup(of: [MediaItem].self) { inner in
                        for library in libraries where library.kind == kind {
                            inner.addTask {
                                // Server-side filter when supported (Plex), else
                                // load all + filter client-side by audio tracks.
                                if case let .some(.some(filtered)) = try? await source.items(in: library.id, audioLanguage: audioLanguage) {
                                    return filtered
                                }
                                let all = (try? await source.items(in: library.id)) ?? []
                                let filter = MediaFilter(audioLanguage: audioLanguage)
                                return all.filter { filter.matchesLocally($0) }
                            }
                        }
                        var acc: [MediaItem] = []
                        for await chunk in inner { acc += chunk }
                        return acc
                    }
                }
            }
            var all: [MediaItem] = []
            for await chunk in group { all += chunk }
            return all
        }
        let downloaded = await downloadedTask
        return Self.merge(items, downloaded: downloaded, serverNames: serverNames)
    }

    /// Audio-language **membership map** for the catalog: `code -> set of
    /// `UnifiedMediaItem.id`` that have an audio track in that language (#319).
    ///
    /// The Library grid builds this once (in the background) and then filters
    /// the already-loaded items client-side — so tapping an audio chip is
    /// instant, with no per-tap server round-trip and no off-by-one from a
    /// stale async result landing after a newer selection. The per-language
    /// queries reuse `unifiedItems(kind:audioLanguage:)` (Plex server-side,
    /// Jellyfin client-side), run concurrently, and dedup the same way as the
    /// base catalog so the ids line up with the displayed items.
    public func audioLanguageMembership(
        kind: MediaItem.Kind, languages: [String]
    ) async -> [String: Set<String>] {
        await withTaskGroup(of: (String, Set<String>).self) { group in
            for code in languages {
                group.addTask { (code, await self.audioLanguageIDs(kind: kind, language: code)) }
            }
            var membership: [String: Set<String>] = [:]
            for await (code, ids) in group { membership[code] = ids }
            return membership
        }
    }

    /// The `UnifiedMediaItem.id`s whose audio includes `code`, for a **single**
    /// language — process-cached (30 min) so the grid resolves an audio-chip tap
    /// lazily (only the tapped language is queried) and re-uses it across opens.
    /// This replaces the eager all-languages warm-up that made the first filter
    /// slow and re-ran every visit (#319 perf). Empty results aren't cached (a
    /// transient empty fan-out, same reasoning as `unifiedItems`).
    public func audioLanguageIDs(kind: MediaItem.Kind, language code: String) async -> Set<String> {
        let key = cacheKey(kind: kind) + "|lang=\(code)"
        if let cached = await AudioLanguageMembershipCache.shared.ids(for: key) { return cached }
        let ids = Set(await unifiedItems(kind: kind, audioLanguage: code).map(\.id))
        if !ids.isEmpty { await AudioLanguageMembershipCache.shared.set(ids, for: key) }
        return ids
    }

    /// Whether the persisted snapshot for `kind` is past the 1-hour staleness
    /// threshold (or absent). Views call this after painting the instant
    /// snapshot to decide whether to kick a silent background refresh.
    public func isStale(kind: MediaItem.Kind, asOf now: Date = Date()) async -> Bool {
        let key = cacheKey(kind: kind)
        guard let snapshot = await snapshotStore.snapshot(for: key) else { return true }
        return snapshot.age(asOf: now) >= Self.snapshotStaleness
    }

    /// Drop every persisted snapshot — call on sign-out or a connected-source
    /// change so a previous login's catalog can't surface on the next launch.
    public func clearSnapshots() async {
        await snapshotStore.clearAll()
    }

    /// Drop the cached + persisted catalog for `kinds` so the next
    /// `unifiedItems(kind:)` re-reads the server. Call after an external
    /// server-side mutation made from the app (e.g. a Jellyfin identify changed
    /// a title's metadata) so surfaces don't keep showing the stale item.
    public func invalidate(kinds: [MediaItem.Kind]) async {
        let keys = kinds.map { cacheKey(kind: $0) }
        await UnifiedLibraryCache.shared.remove(for: keys)
        await snapshotStore.clear(for: keys)
    }

    /// Cache key for `unifiedItems(kind:)` — the kind plus the sorted connected
    /// source ids, so a different source set (sign-in/out, source switch) is a
    /// natural cache miss rather than serving another account's catalog.
    private func cacheKey(kind: MediaItem.Kind) -> String {
        let srcs = sources.map { $0.id.stableKey }.sorted().joined(separator: ",")
        return "\(kind)|\(srcs)"
    }

    private func downloadedIDs() async -> Set<MediaID> {
        guard let downloads else { return [] }
        return Set(await downloads.snapshot().completed.map(\.mediaID))
    }

    // MARK: Cross-source watched

    /// Mark a played item watched (or unwatched) on **every connected source
    /// that has the same title**, not just the source it streamed from. The two
    /// servers are independent, so without this watching a movie that exists on
    /// both Plex and Jellyfin only updates one; this fans the state out across
    /// all of them, matched by shared external id (TMDb/IMDb/TVDB). Episodes are
    /// matched via their show plus season/episode number.
    ///
    /// Best-effort and fault-tolerant: a source that can't be matched is skipped.
    public func markWatchedEverywhere(_ played: MediaItem, watched: Bool = true) async {
        let byID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func apply(_ id: MediaID) async {
            guard let s = byID[id.source] else { return }
            if watched { await s.markWatched(id) } else { await s.markUnwatched(id) }
        }
        // Always update the source it actually played from.
        await apply(played.id)

        switch played.kind {
        case .movie, .show:
            let group = await unifiedItems(kind: played.kind).first { u in
                u.sources.contains { $0.item.id == played.id }
                    || u.sources.contains { Self.sharesGuid($0.item.guids, played.guids) }
            }
            guard let group else { return }
            for s in group.sources where s.item.id != played.id { await apply(s.item.id) }

        case .episode:
            guard let season = played.seasonNumber, let episode = played.episodeNumber else { return }
            let show = await unifiedItems(kind: .show).first { Self.showMatches($0, episode: played) }
            guard let show else { return }
            for s in show.sources where s.item.id.source != played.id.source {
                guard let src = byID[s.item.id.source],
                      let epID = await Self.findEpisode(src, show: s.item.id, season: season, episode: episode)
                else { continue }
                if watched { await src.markWatched(epID) } else { await src.markUnwatched(epID) }
            }
        default:
            break
        }

        // The server now holds the new watched state, but Home / Library /
        // Discover / Search all read this title from the shared unified caches,
        // which still carry the OLD flag — so the poster badge would stay stale
        // until the 45 s TTL lapsed or a relaunch re-fetched. Drop the affected
        // entries (both the in-memory cache and the cross-launch snapshot) so the
        // next `unifiedItems` re-reads the server's fresh state. Movies live under
        // the `.movie` key; episodes roll up into their show's `.show` key.
        let invalidatedKinds: [MediaItem.Kind] = played.kind == .movie ? [.movie] : [.show]
        let keys = invalidatedKinds.map { cacheKey(kind: $0) }
        await UnifiedLibraryCache.shared.remove(for: keys)
        await snapshotStore.clear(for: keys)
    }

    // MARK: Cross-source Continue Watching removal

    /// Remove a title from **Continue Watching** across every connected source
    /// that has it — *without* marking it watched. Reports a server playhead of
    /// **zero** (`recordProgress(position: .zero)`): Plex zeroes `viewOffset` and
    /// Jellyfin zeroes `PlaybackPositionTicks`, so the title drops out of Plex On
    /// Deck / Jellyfin Resume — and therefore out of the server-seeded Continue
    /// Watching read (`serverResumePoints` only surfaces points with a positive
    /// offset). This is the durable, cross-device "remove" the local
    /// `ResumeStore.clear` alone can't be: a local-only clear reappears on the
    /// next server re-seed (`seedServerResume`).
    ///
    /// Distinct from `markWatchedEverywhere` on purpose: "Remove from Continue
    /// Watching" must not flip the watched flag (no ✓ badge, no drop from
    /// hide-watched Discovery, no unwatched-count change). Fans out across
    /// sources matched the same way as the watched path; best-effort +
    /// fault-tolerant. The caller still clears the local `ResumeStore` so the
    /// rail updates instantly before the network round-trips land.
    public func clearContinueWatchingEverywhere(_ played: MediaItem) async {
        let byID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func clear(_ id: MediaID, runtime: Duration?) async {
            guard let s = byID[id.source] else { return }
            await s.recordProgress(id, position: .zero, duration: runtime, paused: true)
        }
        // Always reset the source it actually played from.
        await clear(played.id, runtime: played.runtime)

        switch played.kind {
        case .movie, .show:
            let group = await unifiedItems(kind: played.kind).first { u in
                u.sources.contains { $0.item.id == played.id }
                    || u.sources.contains { Self.sharesGuid($0.item.guids, played.guids) }
            }
            guard let group else { return }
            for s in group.sources where s.item.id != played.id {
                await clear(s.item.id, runtime: s.item.runtime)
            }

        case .episode:
            guard let season = played.seasonNumber, let episode = played.episodeNumber else { return }
            let show = await unifiedItems(kind: .show).first { Self.showMatches($0, episode: played) }
            guard let show else { return }
            for s in show.sources where s.item.id.source != played.id.source {
                guard let src = byID[s.item.id.source],
                      let epID = await Self.findEpisode(src, show: s.item.id, season: season, episode: episode)
                else { continue }
                await src.recordProgress(epID, position: .zero, duration: played.runtime, paused: true)
            }
        default:
            break
        }
    }

    private static func sharesGuid(_ a: MediaGuids, _ b: MediaGuids) -> Bool {
        (a.tmdb != nil && a.tmdb == b.tmdb)
            || (a.imdb != nil && a.imdb == b.imdb)
            || (a.tvdb != nil && a.tvdb == b.tvdb)
    }

    /// A unified show matches a played episode by the episode's show external id
    /// (when carried) or, failing that, a case-insensitive series-title match.
    private static func showMatches(_ show: UnifiedMediaItem, episode: MediaItem) -> Bool {
        if !episode.guids.isEmpty, show.sources.contains(where: { sharesGuid($0.item.guids, episode.guids) }) {
            return true
        }
        guard let series = episode.seriesTitle else { return false }
        return show.title.localizedCaseInsensitiveCompare(series) == .orderedSame
            || show.sources.contains { $0.item.title.localizedCaseInsensitiveCompare(series) == .orderedSame }
    }

    /// The episode id on `source` matching season+episode under `show` — walking
    /// show → (seasons →) episodes, tolerant of sources with or without a season tier.
    private static func findEpisode(_ source: any MediaSource, show: MediaID, season: Int, episode: Int) async -> MediaID? {
        guard let children = try? await source.children(of: show) else { return nil }
        func episodeIn(_ items: [MediaItem]) -> MediaID? {
            items.first { $0.kind == .episode && ($0.seasonNumber ?? 0) == season && ($0.episodeNumber ?? 0) == episode }?.id
        }
        if let direct = episodeIn(children) { return direct }
        // Otherwise children are seasons — descend into the matching one.
        for s in children where s.kind == .season {
            if (s.seasonNumber ?? -1) == season || season == 0,
               let eps = try? await source.children(of: s.id), let found = episodeIn(eps) {
                return found
            }
        }
        return nil
    }

    /// Build the unified Home rails: deduplicated Movies / TV Shows, plus
    /// cross-source Continue Watching (best resume across a title's sources) and
    /// the Downloaded titles. Fault-tolerant via `unifiedItems`.
    public func homeRails(resumeStore: ResumeStore, limit: Int = 30, forceRefresh: Bool = false) async -> UnifiedRails {
        // Movies and shows aggregate concurrently (each already fans out in
        // parallel internally). The catalog comes from `unifiedItems` (cached);
        // Continue Watching below is recomputed from the live `resumeStore` every
        // call, so resume state stays fresh even on a cache hit.
        async let moviesTask = unifiedItems(kind: .movie, forceRefresh: forceRefresh)
        async let showsTask = unifiedItems(kind: .show, forceRefresh: forceRefresh)
        let movies = await moviesTask
        let shows = await showsTask
        // Seed the resume store from each source's server-side "Continue
        // Watching" list (Plex On Deck, Jellyfin Resume) so progress made on
        // other devices surfaces here even with no local history — the
        // cross-device read path, the only one macOS has (no iCloud). Merge is
        // latest-`updatedAt`-wins, so a server point never clobbers a fresher
        // local one.
        //
        // Only on a forced refresh — i.e. the background stale-while-revalidate
        // pass, never the cold cached paint. A network round-trip here would
        // make the first Home/Discover render wait on the servers while the
        // catalog is already cached (parity with iOS, which paints from cache
        // then revalidates). The seeded points are written to the resume store
        // (and disk), so they surface on the revalidate that re-rendered us and
        // instantly on the next launch.
        if forceRefresh { await seedServerResume(into: resumeStore) }

        var continueWatching: [HomeFeed.ContinueWatchingEntry] = []
        for unified in movies + shows {
            var best: (item: MediaItem, resume: ResumePoint)?
            for source in unified.sources {
                guard let resume = await resumeStore.point(for: source.item.id) else { continue }
                if best == nil || Self.seconds(resume.position) > Self.seconds(best!.resume.position) {
                    best = (source.item, resume)
                }
            }
            if let best { continueWatching.append(.init(item: best.item, resume: best.resume)) }
        }

        // In-progress EPISODES (#263). An episode's resume point is keyed by the
        // *episode* id, which is never a top-level catalog item — so the loop
        // above (movies + show *containers*) misses every in-progress episode and
        // no TV show ever reaches Continue Watching. Walk the live resume points,
        // resolve each via its owning source, group by show, and surface the
        // most-recently-watched episode per show ("pick up where you left off").
        continueWatching.append(
            contentsOf: await inProgressEpisodes(resumeStore: resumeStore, excluding: continueWatching)
        )

        // Most recently active first, across movies + TV.
        continueWatching.sort { $0.resume.updatedAt > $1.resume.updatedAt }

        let pool = movies + shows

        // Recently Added: newest library-add date first. When no source dates
        // its items, fall back to merge (source) order so Home isn't blank.
        let dated = pool.filter { $0.dateAdded != nil }
        let recentlyAdded: [UnifiedMediaItem]
        if dated.isEmpty {
            recentlyAdded = Array(Self.interleave(movies, shows).prefix(limit))
        } else {
            recentlyAdded = Array(
                dated.sorted { ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast) }
                    .prefix(limit)
            )
        }

        // Recently Released: newest original-release date first. No fallback —
        // an undated catalog simply hides this rail.
        let recentlyReleased = Array(
            pool.filter { $0.releaseDate != nil }
                .sorted { ($0.releaseDate ?? .distantPast) > ($1.releaseDate ?? .distantPast) }
                .prefix(limit)
        )

        return UnifiedRails(
            continueWatching: continueWatching,
            movies: Array(movies.prefix(limit)),
            shows: Array(shows.prefix(limit)),
            downloaded: pool.filter(\.isDownloaded),
            recentlyAdded: recentlyAdded,
            recentlyReleased: recentlyReleased,
            movieCount: movies.count,
            showCount: shows.count
        )
    }

    /// Pull each source's server-side resume list and merge it into the local
    /// store (latest-`updatedAt`-wins). Fans out across sources; a slow or
    /// failing source can't block the others. Best-effort throughout.
    private func seedServerResume(into resumeStore: ResumeStore) async {
        await withTaskGroup(of: [ResumePoint].self) { group in
            for source in sources {
                group.addTask { await source.serverResumePoints() }
            }
            for await points in group {
                for point in points {
                    await resumeStore.record(point, committing: false)
                }
            }
        }
    }

    /// The most-recently-watched in-progress **episode per show**, resolved from
    /// the live resume points (#263).
    ///
    /// Resume points whose `mediaID` already surfaced as a movie/show entry are
    /// skipped. The rest are routed to their owning source via `item(for:)` and
    /// kept only when they resolve to an episode. Grouping is by **`seriesTitle`**
    /// — the show-level identity that holds even though `parentID` resolves to the
    /// *season* on Plex/Jellyfin, so a multi-season binge collapses to one entry
    /// per show rather than one per season.
    private func inProgressEpisodes(
        resumeStore: ResumeStore,
        excluding existing: [HomeFeed.ContinueWatchingEntry]
    ) async -> [HomeFeed.ContinueWatchingEntry] {
        let points = await resumeStore.allPoints()
        guard !points.isEmpty else { return [] }

        let alreadySurfaced = Set(existing.map(\.item.id))
        let sourcesByID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var byShow: [String: (item: MediaItem, resume: ResumePoint)] = [:]
        for point in points where !alreadySurfaced.contains(point.mediaID) {
            guard let source = sourcesByID[point.mediaID.source],
                  let item = try? await source.item(for: point.mediaID),
                  item.kind == .episode else { continue }
            let showKey = item.seriesTitle.map { $0.lowercased() }
                ?? (item.parentID ?? item.id).key
            if let current = byShow[showKey], current.resume.updatedAt >= point.updatedAt { continue }
            byShow[showKey] = (item, point)
        }

        return byShow.values.map { .init(item: $0.item, resume: $0.resume) }
    }

    /// Round-robin two lists: a, b, a, b, … until both drain. Used for the
    /// Recently Added fallback so neither movies nor shows dominate.
    private static func interleave(
        _ a: [UnifiedMediaItem], _ b: [UnifiedMediaItem]
    ) -> [UnifiedMediaItem] {
        var result: [UnifiedMediaItem] = []
        var index = 0
        while index < a.count || index < b.count {
            if index < a.count { result.append(a[index]) }
            if index < b.count { result.append(b[index]) }
            index += 1
        }
        return result
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    // MARK: - Merge engine (pure, testable)

    public nonisolated static func merge(
        _ items: [MediaItem],
        downloaded: Set<MediaID> = [],
        serverNames: [MediaSourceID: String] = [:]
    ) -> [UnifiedMediaItem] {
        guard !items.isEmpty else { return [] }

        // 1. Union-find over items sharing any identity token.
        var parent = Array(0..<items.count)
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { parent[r] = parent[parent[r]]; r = parent[r] }
            return r
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        var tokenOwner: [String: Int] = [:]
        for (i, item) in items.enumerated() {
            for token in identityTokens(for: item) {
                if let j = tokenOwner[token] { union(i, j) } else { tokenOwner[token] = i }
            }
        }

        // 2. Group item indices by representative, preserving first-seen order.
        var groups: [Int: [Int]] = [:]
        var order: [Int] = []
        for i in items.indices {
            let root = find(i)
            if groups[root] == nil { order.append(root) }
            groups[root, default: []].append(i)
        }

        // 3. Build a UnifiedMediaItem per group.
        return order.map { root in
            let groupItems = groups[root]!.map { items[$0] }
            return makeUnified(groupItems, downloaded: downloaded, serverNames: serverNames)
        }
    }

    // MARK: - Identity

    /// Identity tokens for an item, strongest first. Any shared token merges two
    /// items.
    static func identityTokens(for item: MediaItem) -> [String] {
        var tokens: [String] = []
        if let v = item.guids.tmdb { tokens.append("tmdb:\(v)") }
        if let v = item.guids.imdb { tokens.append("imdb:\(v)") }
        if let v = item.guids.tvdb { tokens.append("tvdb:\(v)") }
        if tokens.isEmpty {
            if let year = item.year {
                tokens.append("ty:\(normalizedTitle(item.title))|\(year)")
            } else {
                // No id and no year → never merge: unique per source item.
                tokens.append("uniq:\(item.id.source.stableKey):\(item.id.rawValue)")
            }
        }
        return tokens
    }

    /// The canonical id for a unified group — the strongest external id shared,
    /// else the title+year token, else a unique token. Stable run-to-run.
    private static func canonicalID(for items: [MediaItem]) -> String {
        if let v = items.compactMap({ $0.guids.tmdb }).first { return "tmdb:\(v)" }
        if let v = items.compactMap({ $0.guids.imdb }).first { return "imdb:\(v)" }
        if let v = items.compactMap({ $0.guids.tvdb }).first { return "tvdb:\(v)" }
        if let first = items.first, let year = first.year {
            return "ty:\(normalizedTitle(first.title))|\(year)"
        }
        let first = items.first
        return "uniq:\(first?.id.source.stableKey ?? "?"):\(first?.id.rawValue ?? "?")"
    }

    /// Lowercased, alphanumerics-only — tolerant of punctuation / spacing for
    /// the title+year fallback.
    static func normalizedTitle(_ title: String) -> String {
        title.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
    }

    // MARK: - Assembly

    private static func makeUnified(
        _ items: [MediaItem],
        downloaded: Set<MediaID>,
        serverNames: [MediaSourceID: String]
    ) -> UnifiedMediaItem {
        var sources: [UnifiedSource] = []
        for item in items {
            if downloaded.contains(item.id) {
                sources.append(UnifiedSource(kind: .offline, item: item, serverName: nil, playable: true))
            }
            if let kind = MediaSourceKind(streaming: item.id.source) {
                sources.append(UnifiedSource(
                    kind: kind,
                    item: item,
                    serverName: serverNames[item.id.source],
                    // A show / season is a *container*: you switch to it and
                    // browse its episodes, so it's "available" on any source
                    // that has it even though the container itself carries no
                    // streamURL. Only a leaf (movie / episode) needs a
                    // resolvable stream. Without this, every series' alternate
                    // source showed as "Unavailable" in the picker (#194).
                    playable: item.kind.isContainer || item.streamURL != nil
                ))
            }
        }
        sources.sort { $0.kind < $1.kind }

        // Representative metadata = the preferred (highest-priority) source's
        // item, falling back to the first item if nothing is playable.
        let lead = sources.first?.item ?? items[0]
        // Pin artwork to the first source (in priority order) that actually
        // carries it, so the image identity stays stable even if the lead flips
        // playability between renders — and so an offline-only lead (which may
        // lack a server artwork source) still shows a server-minted image.
        let pinnedArtwork = sources.compactMap(\.item.artwork).first ?? lead.artwork
        return UnifiedMediaItem(
            id: canonicalID(for: items),
            title: lead.title,
            year: lead.year,
            overview: lead.summary,
            posterURL: lead.posterURL,
            backdropURL: lead.backdropURL,
            type: lead.kind,
            sources: sources,
            artwork: pinnedArtwork,
            genres: lead.genres,
            communityRating: lead.communityRating,
            tmdbRating: lead.tmdbRating,
            releaseDate: lead.releaseDate,
            // Prefer any source that reports an add date (the lead's library may
            // not), so "Recently Added" still works when only one server dates it.
            dateAdded: items.compactMap(\.dateAdded).max() ?? lead.dateAdded
        )
    }
}

// MARK: - Shared TTL cache

/// Process-wide, short-TTL cache for the deduplicated per-kind unified catalog,
/// keyed by `kind + connected-source set`. Lets Home / Library / Discover /
/// Search / the grid reuse one aggregation instead of each re-fetching every
/// server and re-running the dedup on every tab switch / appearance. Bounded by
/// a short TTL (so new server content still surfaces) and bypassed by
/// pull-to-refresh (`forceRefresh`). `UnifiedMediaItem` is `Sendable`, so it's
/// safe to hand across the actor.
private actor UnifiedLibraryCache {
    static let shared = UnifiedLibraryCache()

    private struct Entry { let items: [UnifiedMediaItem]; let at: ContinuousClock.Instant }
    private var store: [String: Entry] = [:]
    private let ttl: Duration = .seconds(45)
    private let clock = ContinuousClock()

    func items(for key: String) -> [UnifiedMediaItem]? {
        guard let entry = store[key], entry.at.duration(to: clock.now) < ttl else { return nil }
        return entry.items
    }

    func set(_ items: [UnifiedMediaItem], for key: String) {
        store[key] = Entry(items: items, at: clock.now)
    }

    /// Drop specific entries (e.g. after a watched toggle) so the next read
    /// re-fetches fresh server state instead of serving the stale catalog.
    func remove(for keys: [String]) {
        for key in keys { store[key] = nil }
    }
}

/// Process-shared cache of per-language audio membership (`UnifiedMediaItem.id`
/// sets), keyed by source-set + kind + language code. Long TTL — audio-language
/// membership of a catalog is stable, and the point is to stop re-querying it on
/// every Library "See all" visit (#319 perf).
private actor AudioLanguageMembershipCache {
    static let shared = AudioLanguageMembershipCache()

    private struct Entry { let ids: Set<String>; let at: ContinuousClock.Instant }
    private var store: [String: Entry] = [:]
    private let ttl: Duration = .seconds(30 * 60)
    private let clock = ContinuousClock()

    func ids(for key: String) -> Set<String>? {
        guard let entry = store[key], entry.at.duration(to: clock.now) < ttl else { return nil }
        return entry.ids
    }

    func set(_ ids: Set<String>, for key: String) {
        store[key] = Entry(ids: ids, at: clock.now)
    }
}
