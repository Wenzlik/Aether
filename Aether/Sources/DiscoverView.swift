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
/// - **Recently Added** — newest titles interleaved across movies and shows.
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

    @State private var hero: UnifiedMediaItem?
    @State private var randomPicks: [UnifiedMediaItem] = []
    @State private var recentlyAdded: [UnifiedMediaItem] = []
    @State private var topRated: [UnifiedMediaItem] = []
    @State private var genreRails: [GenreRail] = []
    @State private var isLoading = false
    /// `true` once at least one `load()` has completed — so the empty state only
    /// shows after a real completed load, never during the first load / refresh.
    @State private var hasLoaded = false
    @State private var loadError: String?

    /// One genre's rail. `id` is the genre name so SwiftUI can diff the rails.
    private struct GenreRail: Identifiable {
        let id: String
        var genre: String { id }
        let items: [UnifiedMediaItem]
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            content
                .aetherScreenBackground()
                #if !os(tvOS)
                .refreshable { await load(forceRefresh: true) }
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
    }

    /// Reload key: the connected source ids (so sign-in / sign-out rebuilds).
    private var sourcesKey: String {
        connectedSources.map { $0.id.stableKey }.sorted().joined(separator: ",")
    }

    private var isEmpty: Bool {
        hero == nil && randomPicks.isEmpty && recentlyAdded.isEmpty
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
                AetherLoadingState(.rails(count: 2))
                    .padding(.top, AetherDesign.Spacing.l)
            } else {
                AetherEmptyState(
                    glyph: "sparkles",
                    title: "Nothing to discover yet",
                    message: "Connect a source and Discover surfaces titles you might have forgotten about."
                )
            }
        } else if let loadError {
            AetherErrorState(
                title: "Couldn't build Discover",
                message: loadError,
                retry: .init { Task { await load() } }
            )
        } else if isLoading || !hasLoaded {
            AetherLoadingState(.rails(count: 2))
                .padding(.top, AetherDesign.Spacing.l)
        } else {
            AetherEmptyState(
                glyph: "tray",
                title: "Library is empty",
                message: "Add some movies or shows to a connected source and they'll surface here."
            )
        }
    }

    private var rails: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                #if os(tvOS)
                AetherTVReloadButton { Task { await load() } }
                    .padding(.horizontal, AetherDesign.Spacing.l)
                    .padding(.top, AetherDesign.Spacing.l)
                #endif
                // Discovery Hub order: a featured pick, then fresh arrivals, the
                // best-rated, genre lanes, and serendipitous picks at the tail.
                if let hero {
                    heroSection(hero)
                }
                if !recentlyAdded.isEmpty {
                    rail(title: "Recently Added", items: recentlyAdded)
                }
                if !topRated.isEmpty {
                    rail(title: "Top Rated", items: topRated)
                }
                ForEach(genreRails) { genreRail in
                    rail(title: genreRail.genre, items: genreRail.items)
                }
                if !randomPicks.isEmpty {
                    rail(title: "Picked for You", items: randomPicks)
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
                AetherCard.hero(
                    title: item.title,
                    subtitle: item.year.map(String.init),
                    posterURL: item.backdropURL ?? item.posterURL
                )
                .frame(maxWidth: .infinity)
                .frame(height: heroHeight)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, AetherDesign.Spacing.l)
        }
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
                            AetherCard.poster(title: item.title, posterURL: item.posterURL, isWatched: item.isWatched)
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
        let movies = await library.unifiedItems(kind: .movie, forceRefresh: forceRefresh)
        let shows = await library.unifiedItems(kind: .show, forceRefresh: forceRefresh)
        let all = movies + shows

        guard !all.isEmpty else {
            resetRails()
            return
        }

        // Hero: one random pick. Random Picks: shuffled, hero excluded.
        let pick = all.randomElement()
        hero = pick
        randomPicks = Array(all.filter { $0.id != pick?.id }.shuffled().prefix(12))

        // Recently Added: each list is already newest-first (source sort
        // survives the merge's first-seen ordering); interleave movies + shows
        // so neither dominates, drop the hero, cap at 12.
        recentlyAdded = Array(
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

        // Genre rails: the catalog's most common genres, one shuffled rail each.
        genreRails = topGenres(in: all).map { genre in
            GenreRail(
                id: genre,
                items: Array(all.filter { $0.genres.contains(genre) }.shuffled().prefix(12))
            )
        }

        // Warm the artwork cache for the rails we're about to show. Built up
        // step by step with an explicit type — a single long `+` chain of
        // `[URL?]` arrays blows the Swift type-checker's time budget.
        var artworkURLs: [URL?] = [pick?.backdropURL ?? pick?.posterURL]
        artworkURLs += randomPicks.map(\.posterURL)
        artworkURLs += topRated.map(\.posterURL)
        artworkURLs += recentlyAdded.map(\.posterURL)
        for genreRail in genreRails {
            artworkURLs += genreRail.items.map(\.posterURL)
        }
        AetherImageCache.shared.prefetch(artworkURLs)
    }

    private func resetRails() {
        hero = nil
        randomPicks = []
        recentlyAdded = []
        topRated = []
        genreRails = []
    }

    /// The catalog's most common genres (most frequent first), capped to a few
    /// so Discover doesn't turn into an endless wall of rails. Only genres with
    /// enough titles to fill a rail are kept.
    private func topGenres(in items: [UnifiedMediaItem]) -> [String] {
        var counts: [String: Int] = [:]
        for item in items {
            for genre in item.genres { counts[genre, default: 0] += 1 }
        }
        return counts
            .filter { $0.value >= 4 }
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(4)
            .map(\.key)
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
