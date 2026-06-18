import SwiftUI
import Combine
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
    @Environment(\.posterRatingSource) private var posterRatingSource

    /// The featured carousel (#381): 3–7 slides, in-progress titles first
    /// (most-recently-active), then top-rated, then random picks — a rotating
    /// "what should I watch next?" hero instead of one static random pick.
    @State private var heroItems: [UnifiedMediaItem] = []
    /// Fractional progress (0…1) per hero slide that has a resume point — drives
    /// the thin Continue-Watching strip on that slide. Keyed by item id.
    @State private var heroProgress: [String: Double] = [:]
    /// The visible carousel page.
    @State private var heroIndex = 0
    /// Seconds until the carousel auto-advances (counts down each tick). Reset to
    /// the full interval after any manual interaction.
    @State private var advanceCountdown = 6
    /// While > 0 the carousel is paused after an interaction; it counts down to 0
    /// over the idle window, then auto-advance resumes (#381: resume after 3 s).
    @State private var pauseCountdown = 0
    /// Set while `advanceHero` is moving the page programmatically, so the
    /// `heroIndex` `onChange` can tell an auto-advance apart from a real user
    /// swipe (only the latter should pause auto-advance).
    @State private var programmaticAdvance = false
    #if !os(tvOS)
    /// Measured width of the touch/spatial hero carousel, used to size the
    /// cinematic full-width banner on iPad / visionOS (see `resolvedHeroHeight`).
    @State private var heroContentWidth: CGFloat = 0
    #endif
    /// Reduce Motion disables auto-advance entirely (#381) — manual swipe stays.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(tvOS)
    /// tvOS: auto-advance pauses while the hero has focus (#381).
    @FocusState private var heroFocused: Bool
    #endif
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

    /// Carousel auto-advance interval (seconds) and the idle window before
    /// auto-advance resumes after a manual interaction (#381).
    private static let autoAdvanceInterval = 6
    private static let resumeIdleSeconds = 3
    /// 1 Hz tick driving the countdown-based auto-advance (gives precise
    /// pause-on-interaction / resume-after-idle without re-arming timers).
    private let carouselTicker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

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
        heroItems.isEmpty && randomPicks.isEmpty && newReleases.isEmpty
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

    /// Vertical gap between Discover sections. Wider on the wide layouts (iPad
    /// regular / visionOS) so the full-width hero and the rails below it breathe;
    /// iPhone / tvOS keep the standard spacing.
    private var sectionSpacing: CGFloat {
        #if os(visionOS)
        AetherDesign.Spacing.xxl
        #elseif os(iOS)
        horizontalSizeClass == .regular ? AetherDesign.Spacing.xxl : AetherDesign.Spacing.xl
        #else
        AetherDesign.Spacing.xl
        #endif
    }

    private var rails: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: sectionSpacing) {
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
                if !heroItems.isEmpty {
                    heroCarousel
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

    // MARK: - Featured carousel (#381)

    /// Rotating featured carousel: in-progress titles first (most-recently
    /// active), then top-rated, then random picks — a "what should I watch next?"
    /// hero instead of one static random pick. Auto-advances every 6 s, pauses on
    /// interaction (touch) / focus (tvOS), resumes after a 3 s idle, and stops
    /// auto-advancing entirely under Reduce Motion. Pagination dots underneath.
    @ViewBuilder
    private var heroCarousel: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            AetherSectionHeader(title: "Featured", subtitle: "Curated from your library")
            #if os(tvOS)
            tvFeaturedCarousel
            #else
            touchFeaturedCarousel
            #endif
            if heroItems.count > 1 {
                heroPageDots
                    .padding(.horizontal, AetherDesign.Spacing.l)
            }
        }
        .onReceive(carouselTicker) { _ in autoAdvanceTick() }
    }

    /// Pagination dots — accent for the current slide. One accessibility element
    /// announcing "Featured — slide N of M".
    private var heroPageDots: some View {
        HStack(spacing: AetherDesign.Spacing.xs) {
            ForEach(heroItems.indices, id: \.self) { i in
                Circle()
                    .fill(i == heroIndex
                          ? AetherDesign.Palette.accent
                          : AetherDesign.Palette.textTertiary.opacity(0.4))
                    .frame(width: 7, height: 7)
            }
        }
        // Center the dots under the hero on every platform (they used to hug the
        // leading edge inside the section padding).
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: heroIndex)
        .accessibilityElement()
        .accessibilityLabel(Text("Featured"))
        .accessibilityValue(Text("Slide \(heroIndex + 1) of \(heroItems.count)"))
    }

    #if !os(tvOS)
    /// Swipeable paged carousel for touch / spatial platforms. A horizontal drag
    /// pages; a tap opens Detail. A genuine user swipe pauses auto-advance.
    ///
    /// Wide layouts (iPad / visionOS) use `wideHeroSlide` — a full-bleed backdrop
    /// with title + metadata overlaid on a gradient scrim. Compact (iPhone) keeps
    /// the standard `AetherCard.hero` with the title block below.
    private var touchFeaturedCarousel: some View {
        let h = resolvedHeroHeight
        return TabView(selection: $heroIndex) {
            ForEach(Array(heroItems.enumerated()), id: \.element.id) { index, item in
                NavigationLink(value: item) {
                    if isWideHero {
                        wideHeroSlide(item, height: h)
                    } else {
                        AetherCard.hero(
                            title: item.title,
                            subtitle: featuredMetaLine(item),
                            posterURL: item.backdropURL ?? item.posterURL,
                            progress: heroProgress[item.id],
                            rating: item.posterRating(source: posterRatingSource),
                            aspectRatio: heroAspect
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: h)
                    }
                }
                .buttonStyle(.plain)
                .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: h)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { heroContentWidth = $0 }
        .padding(.horizontal, AetherDesign.Spacing.l)
        .onChange(of: heroIndex) { _, _ in
            if programmaticAdvance { programmaticAdvance = false }
            else { pauseCountdown = Self.resumeIdleSeconds }
        }
    }

    /// Full-bleed overlay hero for iPad / visionOS: backdrop image fills the frame,
    /// title + metadata are overlaid on a gradient scrim at the bottom edge, and a
    /// thin progress bar runs along the very bottom for in-progress titles.
    private func wideHeroSlide(_ item: UnifiedMediaItem, height: CGFloat) -> some View {
        CachedAsyncImage(url: item.backdropURL ?? item.posterURL)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .clipped()
            // Bottom gradient scrim + overlaid title / metadata
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: AetherDesign.Spacing.xxs) {
                    Text(item.title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                        .lineLimit(2)
                    if let meta = featuredMetaLine(item) {
                        Text(meta)
                            .font(AetherDesign.Typography.metadata)
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, AetherDesign.Spacing.m)
                // Extra bottom clearance when the progress bar is visible
                .padding(.bottom, heroProgress[item.id] != nil
                         ? AetherDesign.Spacing.m + 7
                         : AetherDesign.Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.72)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: height * 0.55)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            // Rating badge — top-leading, consistent with AetherCard
            .overlay(alignment: .topLeading) {
                if let rating = item.posterRating(source: posterRatingSource), rating > 0 {
                    Text(String(format: "%.1f", rating))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay { Capsule().stroke(.white.opacity(0.15), lineWidth: 0.5) }
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .padding(AetherDesign.Spacing.xs)
                }
            }
            // Continue-watching bar along the very bottom edge
            .overlay(alignment: .bottom) {
                if let fraction = heroProgress[item.id] {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.white.opacity(0.25))
                            Rectangle()
                                .fill(AetherDesign.Gradients.progress)
                                .frame(width: max(4, geo.size.width * CGFloat(fraction)))
                        }
                    }
                    .frame(height: 3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous))
    }

    /// `true` on the wide layouts (iPad regular width / visionOS) where the hero
    /// should fill the content width with a cinematic crop; `false` on iPhone,
    /// which keeps the compact fixed-height 16:9 hero.
    private var isWideHero: Bool {
        #if os(visionOS)
        true
        #elseif os(iOS)
        horizontalSizeClass == .regular
        #else
        false
        #endif
    }

    /// Cinematic ratio for the wide hero so a full-width banner stays a sensible
    /// height; the compact iPhone hero keeps the backdrop's native 16:9.
    private var heroAspect: CGFloat {
        isWideHero ? 2.7 : 16.0 / 9.0
    }

    /// Hero height. Wide layouts derive it from the measured content width at the
    /// cinematic aspect ratio; title + metadata are overlaid so no bottom allowance
    /// is needed. iPhone keeps the original fixed height.
    private var resolvedHeroHeight: CGFloat {
        guard isWideHero else { return heroHeight }
        guard heroContentWidth > 0 else {
            #if os(visionOS)
            return 360
            #else
            return 280
            #endif
        }
        return heroContentWidth / heroAspect
    }
    #endif

    #if os(tvOS)
    /// tvOS Featured: the side-by-side hero whose content swaps per slide.
    /// Auto-advance pauses while the hero is focused (so the Select target stays
    /// put while the user is on it) and resumes once focus moves to the rails.
    private var tvFeaturedCarousel: some View {
        let item = heroItems[min(heroIndex, heroItems.count - 1)]
        return NavigationLink(value: item) {
            featuredHeroTV(item)
        }
        .buttonStyle(.plain)
        .focused($heroFocused)
        .padding(.horizontal, AetherDesign.Spacing.l)
    }

    /// tvOS Featured presentation: a constrained 16:9 artwork (the card *is* the
    /// artwork — no oversized focus panel or empty letterbox) that lifts gently
    /// on focus, with title / year / genres / synopsis beside it so the section
    /// reads as a purposeful recommendation rather than a giant focus box.
    /// Tapping opens Detail, where Play / Resume live. A thin progress bar shows
    /// when the slide is a resumable in-progress title (#381).
    private func featuredHeroTV(_ item: UnifiedMediaItem) -> some View {
        HStack(alignment: .center, spacing: AetherDesign.Spacing.xl) {
            CachedAsyncImage(
                url: item.backdropURL(.backdropLarge) ?? item.posterURL,
                aspectRatio: 16.0 / 9.0,
                maxPixel: ArtworkTier.backdropLarge.maxPixel
            )
            .frame(width: 600)
            .overlay(alignment: .bottom) { tvHeroProgressBar(for: item) }
            .clipShape(RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous))
            // Trimmed from 760 → 600 (≈428pt → ≈338pt tall at 16:9) so Featured
            // stops dominating the page and the rails below show without scrolling
            // (#266 tvOS feedback). Still the prominent top recommendation.
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
        // Swap-in fade so the side-by-side content reads as a slide transition.
        .id(item.id)
        .transition(.opacity)
    }

    /// Thin Continue-Watching strip along the tvOS hero artwork's lower edge,
    /// shown only for an in-progress (resumable) slide.
    @ViewBuilder
    private func tvHeroProgressBar(for item: UnifiedMediaItem) -> some View {
        if let fraction = heroProgress[item.id] {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.45))
                    Capsule()
                        .fill(AetherDesign.Gradients.progress)
                        .frame(width: max(6, geo.size.width * fraction))
                }
            }
            .frame(height: 6)
            .padding(.horizontal, AetherDesign.Spacing.s)
            .padding(.bottom, AetherDesign.Spacing.s)
        }
    }
    #endif

    /// "2018 · Drama · Biography" — year then up to two genres.
    private func featuredMetaLine(_ item: UnifiedMediaItem) -> String? {
        var parts: [String] = []
        if let year = item.year { parts.append(String(year)) }
        parts.append(contentsOf: item.genres.prefix(2))
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Carousel auto-advance

    /// One 1 Hz tick: count down to the next auto-advance, honouring the pause
    /// window after an interaction and (tvOS) hero focus, and Reduce Motion.
    private func autoAdvanceTick() {
        // The 1 Hz ticker keeps publishing while the app is alive behind a
        // playing audio session; don't wake the CPU to advance an off-screen
        // carousel. It resumes when the app returns to the foreground.
        guard scenePhase == .active else { return }
        guard heroItems.count > 1, !reduceMotion else { return }
        #if os(tvOS)
        if heroFocused { return }   // pause while the hero has focus (#381)
        #endif
        if pauseCountdown > 0 { pauseCountdown -= 1; return }
        advanceCountdown -= 1
        if advanceCountdown <= 0 {
            advanceHero(by: 1, interaction: false)
        }
    }

    /// Move the carousel by `delta` slides (wrapping). `interaction` marks a
    /// manual move so auto-advance pauses for the idle window afterwards.
    private func advanceHero(by delta: Int, interaction: Bool) {
        guard !heroItems.isEmpty else { return }
        programmaticAdvance = !interaction
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
            heroIndex = (heroIndex + delta + heroItems.count) % heroItems.count
        }
        advanceCountdown = Self.autoAdvanceInterval
        if interaction { pauseCountdown = Self.resumeIdleSeconds }
    }

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
        #elseif os(visionOS)
        // Wider tiles so the rails keep pace with the full-width spatial hero.
        220
        #else
        // iPad (regular) gets larger tiles to match the full-width hero; iPhone
        // (compact) keeps the original size.
        horizontalSizeClass == .regular ? 200 : 168
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

        // --- Featured carousel (#381): in-progress titles first (most-recently
        // active), then top-rated, then random — capped at 7. In-progress titles
        // were filtered out of `all` (counted as "started"), so pull them from
        // the unfiltered union and intersect against the resume points.
        let resumePoints = await resumeStore.allPoints()
        let resumeByID = Dictionary(resumePoints.map { ($0.mediaID, $0) },
                                    uniquingKeysWith: { $0.updatedAt >= $1.updatedAt ? $0 : $1 })
        func resumePoint(for item: UnifiedMediaItem) -> ResumePoint? {
            item.sources.compactMap { resumeByID[$0.item.id] }.max { $0.updatedAt < $1.updatedAt }
        }
        let inProgressHeroes = (allMovies + allShows)
            .compactMap { item -> (UnifiedMediaItem, ResumePoint)? in
                guard !item.isFullyWatched, let point = resumePoint(for: item) else { return nil }
                return (item, point)
            }
            .sorted { $0.1.updatedAt > $1.1.updatedAt }
            .prefix(3)

        var heroBuilt: [UnifiedMediaItem] = []
        var heroSeen = Set<String>()
        var heroProgressBuilt: [String: Double] = [:]
        func addHero(_ item: UnifiedMediaItem, resume: ResumePoint?) {
            guard heroBuilt.count < 7, heroSeen.insert(item.id).inserted else { return }
            heroBuilt.append(item)
            if let resume, let fraction = progressFraction(item: item, resume: resume) {
                heroProgressBuilt[item.id] = fraction
            }
        }
        for (item, point) in inProgressHeroes { addHero(item, resume: point) }
        for item in all.filter({ ($0.communityRating ?? 0) > 0 })
            .sorted(by: { ($0.communityRating ?? 0) > ($1.communityRating ?? 0) })
            .prefix(3) {
            addHero(item, resume: nil)
        }
        for item in all.shuffled() where heroBuilt.count < 7 {
            addHero(item, resume: nil)
        }
        heroItems = heroBuilt
        heroProgress = heroProgressBuilt
        heroIndex = min(heroIndex, max(0, heroBuilt.count - 1))
        advanceCountdown = Self.autoAdvanceInterval
        let heroIDs = heroSeen

        // Random Picks: shuffled, carousel slides excluded.
        randomPicks = Array(all.filter { !heroIDs.contains($0.id) }.shuffled().prefix(12))

        // New Releases: each list is already newest-first (source sort survives
        // the merge's first-seen ordering); interleave movies + shows so neither
        // dominates, drop the carousel slides, cap at 12. (#350: was "Recently Added".)
        newReleases = Array(
            interleave(movies, shows)
                .filter { !heroIDs.contains($0.id) }
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
        var artworkURLs: [URL?] = heroBuilt.map { $0.backdropURL ?? $0.posterURL }
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

    /// Fractional progress (0…1) for an in-progress hero slide — `position` over
    /// the runtime of the source that owns the resume point (else any source).
    /// `nil` when no known runtime, mirroring `ContinueWatchingEntry.progress`.
    private func progressFraction(item: UnifiedMediaItem, resume: ResumePoint) -> Double? {
        let runtime = item.sources.first(where: { $0.item.id == resume.mediaID })?.item.runtime
            ?? item.sources.first?.item.runtime
        guard let runtime, runtime > .zero else { return nil }
        let total = durationSeconds(runtime)
        guard total > 0 else { return nil }
        return min(1, max(0, durationSeconds(resume.position) / total))
    }

    private func durationSeconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private func resetRails() {
        heroItems = []
        heroProgress = [:]
        heroIndex = 0
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
