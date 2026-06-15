import SwiftUI
import AetherCore

/// **Discover** — a first-class content tab on every platform.
///
/// Surfaces a curated *find-something-new* experience on top of the user's
/// existing library — now **unified** across every connected source:
///
/// - **Hero pick** — one big artwork, randomly drawn across the whole
///   deduplicated catalog on each build.
/// - **Random Picks** — a shuffled rail; rediscover titles you own but forgot.
/// - **New Releases** — newest titles interleaved across movies and shows.
///
/// Data comes from `UnifiedLibrary` (the same aggregator Home / Search use), so
/// a title on both Plex and Jellyfin appears once and each card navigates a
/// `UnifiedMediaItem` (Detail shows its Available Sources). The shuffle is
/// re-rolled per build so returning users see different picks.
struct DiscoverView: View {
    /// Lifted from `RootTabView` so re-selecting the Discover tab can pop to root.
    @Binding var navigationPath: NavigationPath
    /// Every connected source — aggregated + deduplicated by `UnifiedLibrary`.
    let connectedSources: [any MediaSource]
    /// `true` while `AppSession` is still starting up / discovering. While it is,
    /// an empty result means "still connecting" → show loading, not the empty
    /// state.
    let isConnecting: Bool
    /// Backs the unified aggregator's offline fold-in.
    let downloadStore: DownloadStore?
    let resumeStore: ResumeStore
    let playbackSession: PlaybackSession
    let libraryPreferences: LibraryPreferencesStore
    let downloadManager: DownloadManager?
    let downloads: DownloadObserver?
    let playbackPreferences: PlaybackPreferencesStore?

    /// Netflix availability (#360): badges on owned posters + the Netflix-only
    /// discovery rails.
    @Environment(WatchAvailabilityStore.self) private var availability: WatchAvailabilityStore?

    @State private var hero: UnifiedMediaItem?
    @State private var randomPicks: [UnifiedMediaItem] = []
    @State private var newReleases: [UnifiedMediaItem] = []
    @State private var topRated: [UnifiedMediaItem] = []
    /// Netflix-only titles (not owned) — "New on Netflix" / "Top on Netflix"
    /// (#360). Empty unless the feature + "show Netflix-only" are both on.
    @State private var netflixNew: [UnifiedMediaItem] = []
    @State private var netflixTop: [UnifiedMediaItem] = []
    @State private var isLoading = false
    /// `true` once at least one `load()` has completed — so the empty state only
    /// shows after a real completed load, never during the first load / refresh.
    @State private var hasLoaded = false
    @State private var loadError: String?
    /// One automatic retry on an empty result (transient first-load), so Discover
    /// self-heals instead of sticking on an empty state.
    @State private var autoRetried = false
    /// Reload (non-destructively) when the app returns to the foreground.
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    /// iPad (regular) shows the brand mark as a top tab-bar toolbar icon, like
    /// Home / Library; compact (iPhone) keeps the inline wordmark header.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// iPad regular width — brand icon rides the top tab-bar row.
    private var usesTopBarChrome: Bool {
        #if os(iOS)
        horizontalSizeClass == .regular
        #else
        false
        #endif
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            content
                .aetherScreenBackground()
                #if !os(tvOS)
                .refreshable { await load(forceRefresh: true) }
                #endif
                // iPad: brand icon on the top tab-bar row (parity with Home /
                // Library); tapping it pops Discover to root.
                #if os(iOS)
                .toolbar {
                    if usesTopBarChrome {
                        ToolbarItem(placement: .topBarLeading) {
                            AetherBrandIcon { navigationPath = NavigationPath() }
                        }
                    }
                }
                #endif
                .mediaNavigationDestinations(
                    source: connectedSources.first,
                    connectedSources: connectedSources,
                    resumeStore: resumeStore,
                    playbackSession: playbackSession,
                    libraryPreferences: libraryPreferences,
                    downloadManager: downloadManager,
                    downloads: downloads,
                    playbackPreferences: playbackPreferences
                )
        }
        .task(id: sourcesKey) { await load() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await load() } }
        }
    }

    /// Reload key: the connected source ids (so sign-in / sign-out rebuilds).
    private var sourcesKey: String {
        connectedSources.map { $0.id.stableKey }.sorted().joined(separator: ",")
    }

    private var isEmpty: Bool {
        hero == nil && randomPicks.isEmpty && newReleases.isEmpty
    }

    @ViewBuilder
    private var content: some View {
        if !isEmpty {
            // Have content → keep it shown, even while a refresh is running.
            rails
        } else if connectedSources.isEmpty {
            // Empty sources: loading while still connecting at startup; only a
            // settled startup means "no source connected".
            if isConnecting {
                AetherCenteredScrollState {
                    AetherLoadingDots(caption: "Loading Discover…")
                }
            } else {
                AetherCenteredScrollState {
                    AetherEmptyState(
                        glyph: "sparkles",
                        title: "Nothing to discover yet",
                        message: "Connect a source and Discover surfaces titles you might have forgotten about."
                    )
                }
            }
        } else if let loadError {
            AetherCenteredScrollState {
                AetherErrorState(
                    title: "Couldn't build Discover",
                    message: loadError,
                    retry: .init { Task { await load() } }
                )
            }
        } else if isLoading || !hasLoaded {
            AetherCenteredScrollState {
                AetherLoadingDots(caption: "Loading Discover…")
            }
        } else {
            AetherCenteredScrollState {
                AetherEmptyState(
                    glyph: "tray",
                    title: "Library is empty",
                    message: "Add some movies or shows to a connected source and they'll surface here."
                )
            }
        }
    }

    private var rails: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                // Brand mark leads Discover too, consistent across Home / Library
                // / Discover. On iPad it rides the top tab-bar row (toolbar icon),
                // so the inline wordmark header shows only on compact / tvOS.
                // Discover has no search field; Reload rides the trailing edge on
                // tvOS (no pull-to-refresh there).
                if !usesTopBarChrome {
                    HStack(spacing: AetherDesign.Spacing.m) {
                        AetherWordmark(.medium)
                        Spacer(minLength: AetherDesign.Spacing.l)
                        #if os(tvOS)
                        AetherTVReloadButton { Task { await load() } }
                            .frame(width: 260)
                        #endif
                    }
                    .padding(.horizontal, AetherDesign.Spacing.l)
                    .padding(.top, AetherDesign.Spacing.l)
                    .padding(.bottom, AetherDesign.Spacing.xs)
                }
                // Discovery Hub order: a featured pick, then fresh arrivals, the
                // best-rated, and serendipitous picks at the tail. Genre lanes were
                // removed (#350) — Library already has genre browse; Discover is
                // for "what should I watch", so it leads with curated rails.
                if let hero {
                    heroSection(hero)
                }
                if !newReleases.isEmpty {
                    rail(title: "New Releases", items: newReleases)
                }
                if !topRated.isEmpty {
                    rail(title: "Top Rated", items: topRated)
                }
                if !randomPicks.isEmpty {
                    rail(title: "Picked for You", items: randomPicks)
                }
                // Netflix-only discovery (#360) — opt-in, after the owned rails.
                if !netflixNew.isEmpty {
                    rail(title: "New on Netflix", items: netflixNew)
                }
                if !netflixTop.isEmpty {
                    rail(title: "Top on Netflix", items: netflixTop)
                }
            }
            .padding(.bottom, AetherDesign.Spacing.xxl)
        }
    }

    // MARK: - Sections

    /// A wide single-card hero showing one randomly-picked title, tappable
    /// straight into Detail. A *single* artwork (not a rail) so the random pick
    /// reads as "this is the title we're suggesting."
    private func heroSection(_ item: UnifiedMediaItem) -> some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            AetherSectionHeader(title: "Featured", subtitle: "Curated from your library")

            NavigationLink(value: item) {
                #if os(tvOS)
                featuredHeroTV(item)
                #else
                AetherCard.hero(
                    title: item.title,
                    subtitle: item.year.map(String.init),
                    posterURL: item.backdropURL ?? item.posterURL
                )
                .frame(maxWidth: .infinity)
                .frame(height: heroHeight)
                #endif
            }
            .buttonStyle(.plain)
            .padding(.horizontal, AetherDesign.Spacing.l)
        }
    }

    #if os(tvOS)
    /// tvOS Featured presentation: a constrained 16:9 artwork (the card *is* the
    /// artwork — no oversized focus panel or empty letterbox) that lifts gently
    /// on focus, with title / year / genres / synopsis beside it so the section
    /// reads as a purposeful recommendation rather than a giant focus box.
    /// Tapping opens Detail, where Play / Resume live.
    private func featuredHeroTV(_ item: UnifiedMediaItem) -> some View {
        HStack(alignment: .center, spacing: AetherDesign.Spacing.xl) {
            CachedAsyncImage(
                url: item.backdropURL(.backdropLarge) ?? item.posterURL,
                aspectRatio: 16.0 / 9.0,
                maxPixel: ArtworkTier.backdropLarge.maxPixel
            )
            .clipShape(RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous))
            // Trimmed from 760 → 600 (≈428pt → ≈338pt tall at 16:9) so Featured
            // stops dominating the page and the rails below show without scrolling
            // (#266 tvOS feedback). Still the prominent top recommendation.
            .frame(width: 600)
            .premiumFocus(scale: 1.04)

            VStack(alignment: .leading, spacing: AetherDesign.Spacing.s) {
                Text(item.title)
                    .font(AetherDesign.Typography.heroTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                    .lineLimit(2)
                if let meta = featuredMetaLine(item) {
                    Text(meta)
                        .font(AetherDesign.Typography.metadata)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                        .lineLimit(1)
                }
                if let overview = item.overview, !overview.isEmpty {
                    Text(overview)
                        .font(AetherDesign.Typography.body)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "2018 · Drama · Biography" — year then up to two genres.
    private func featuredMetaLine(_ item: UnifiedMediaItem) -> String? {
        var parts: [String] = []
        if let year = item.year { parts.append(String(year)) }
        parts.append(contentsOf: item.genres.prefix(2))
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    #endif

    private var heroHeight: CGFloat {
        #if os(tvOS)
        480
        #else
        240
        #endif
    }

    private var posterWidth: CGFloat {
        #if os(tvOS)
        300
        #else
        168
        #endif
    }

    /// Generic horizontal poster rail of unified titles.
    private func rail(title: String, items: [UnifiedMediaItem]) -> some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            AetherSectionHeader(title: title)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: AetherDesign.Spacing.l) {
                    ForEach(items) { item in
                        NavigationLink(value: item) {
                            AetherCard.poster(title: item.title, posterURL: item.posterURL, isWatched: item.isFullyWatched, netflixLogoURL: availability?.netflixLogoURL(for: item))
                                .frame(width: posterWidth)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, AetherDesign.Spacing.l)
                .padding(.vertical, AetherDesign.Spacing.xs)
            }
            .aetherDiscoverFocusSection()
        }
    }

    // MARK: - Loading

    private func load(forceRefresh: Bool = false) async {
        loadError = nil
        defer { hasLoaded = true }

        guard !connectedSources.isEmpty else {
            resetRails()
            isLoading = false
            return
        }

        isLoading = true
        defer { isLoading = false }

        let library = UnifiedLibrary(sources: connectedSources, downloads: downloadStore)
        let allMovies = await library.unifiedItems(kind: .movie, forceRefresh: forceRefresh)
        let allShows = await library.unifiedItems(kind: .show, forceRefresh: forceRefresh)
        // Discover recommends what's *ahead*. With the (default-on) hide-watched
        // preference, both fully-watched **and** in-progress titles drop out of
        // every rail (#350) — those live in Continue Watching, not Discover.
        // In-progress = has a local resume point (the same signal Continue
        // Watching intersects against), matched by any of the title's source ids.
        let hideWatched = playbackPreferences?.hideWatchedInDiscovery ?? true
        let inProgressIDs = Set(await resumeStore.allPoints().map(\.mediaID))
        func isStarted(_ item: UnifiedMediaItem) -> Bool {
            item.sources.contains { inProgressIDs.contains($0.item.id) }
        }
        func surfaceable(_ items: [UnifiedMediaItem]) -> [UnifiedMediaItem] {
            guard hideWatched else { return items }
            return items.filter { !$0.isFullyWatched && !isStarted($0) }
        }
        let movies = surfaceable(allMovies)
        let shows = surfaceable(allShows)
        let all = movies + shows

        guard !all.isEmpty else {
            // A refresh came back empty: if we already have content on screen
            // (transient source hiccup), keep it; only blank when we had nothing.
            // Retry once either way so a transient empty self-heals.
            if isEmpty { resetRails() }
            scheduleAutoRetryIfNeeded()
            return
        }
        autoRetried = false   // real content available → reset the retry budget

        // Stale-while-revalidate (#197): a cold launch paints the persisted
        // snapshot instantly; refresh silently if it's past the 1-hour window
        // (content stays on screen — the spinner only shows over an empty view).
        if !forceRefresh {
            let staleMovies = await library.isStale(kind: .movie)
            let staleShows = await library.isStale(kind: .show)
            if staleMovies || staleShows { Task { await load(forceRefresh: true) } }
        }

        // Hero: one random pick. Random Picks: shuffled, hero excluded.
        let pick = all.randomElement()
        hero = pick
        randomPicks = Array(all.filter { $0.id != pick?.id }.shuffled().prefix(12))

        // New Releases: each list is already newest-first (source sort survives
        // the merge's first-seen ordering); interleave movies + shows so neither
        // dominates, drop the hero, cap at 12. (#350: was "Recently Added".)
        newReleases = Array(
            interleave(movies, shows)
                .filter { $0.id != pick?.id }
                .prefix(12)
        )

        // Top Rated: highest community rating first, only titles that carry one.
        topRated = Array(
            all.filter { ($0.communityRating ?? 0) > 0 }
                .sorted { ($0.communityRating ?? 0) > ($1.communityRating ?? 0) }
                .prefix(12)
        )

        // Warm the artwork cache for the rails we're about to show. Built up
        // step by step with an explicit type — a single long `+` chain of
        // `[URL?]` arrays blows the Swift type-checker's time budget.
        var artworkURLs: [URL?] = [pick?.backdropURL ?? pick?.posterURL]
        artworkURLs += randomPicks.map(\.posterURL)
        artworkURLs += topRated.map(\.posterURL)
        artworkURLs += newReleases.map(\.posterURL)
        AetherImageCache.shared.prefetch(artworkURLs)

        // Netflix-only rails (#360) — opt-in, deduped against owned titles.
        await loadNetflixRails(ownedTMDbIDs: Set(all.compactMap(\.tmdbID)))
    }

    /// Build the "New on Netflix" / "Top on Netflix" rails (movies), filtering
    /// out titles already in the user's library. No-op unless the feature +
    /// "show Netflix-only" are on, or there's no TMDb key. (#360)
    private func loadNetflixRails(ownedTMDbIDs: Set<String>) async {
        guard let availability, availability.showsNetflixOnly else {
            netflixNew = []; netflixTop = []
            return
        }
        func unowned(_ items: [UnifiedMediaItem]) -> [UnifiedMediaItem] {
            items.filter { item in item.tmdbID.map { !ownedTMDbIDs.contains($0) } ?? true }
        }
        let new = await availability.netflixOnlyDiscover(isShow: false, sort: .newest)
        let top = await availability.netflixOnlyDiscover(isShow: false, sort: .topRated)
        netflixNew = Array(unowned(new).prefix(12))
        netflixTop = Array(unowned(top).prefix(12))
        AetherImageCache.shared.prefetch((netflixNew + netflixTop).map(\.posterURL))
    }

    private func resetRails() {
        hero = nil
        randomPicks = []
        newReleases = []
        topRated = []
        netflixNew = []
        netflixTop = []
    }

    /// One automatic retry when a connected source returns empty (often a
    /// transient first-load), so Discover self-heals instead of sticking.
    /// Bounded by `autoRetried`; pull-to-refresh + foreground reload cover more.
    private func scheduleAutoRetryIfNeeded() {
        guard !autoRetried, !connectedSources.isEmpty else { return }
        autoRetried = true
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, isEmpty else { return }
            await load(forceRefresh: true)
        }
    }

    /// Round-robin two lists: a, b, a, b, … until both drain.
    private func interleave(_ a: [UnifiedMediaItem], _ b: [UnifiedMediaItem]) -> [UnifiedMediaItem] {
        var result: [UnifiedMediaItem] = []
        var i = 0
        while i < a.count || i < b.count {
            if i < a.count { result.append(a[i]) }
            if i < b.count { result.append(b[i]) }
            i += 1
        }
        return result
    }
}

private extension View {
    /// `.focusSection()` on tvOS for predictable D-pad movement between rails;
    /// no-op elsewhere (the API is tvOS-only).
    @ViewBuilder
    func aetherDiscoverFocusSection() -> some View {
        #if os(tvOS)
        self.focusSection()
        #else
        self
        #endif
    }
}
