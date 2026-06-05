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
    @State private var isLoading = false
    @State private var loadError: String?

    var body: some View {
        NavigationStack(path: $navigationPath) {
            content
                .background(AetherDesign.Gradients.background.ignoresSafeArea())
                #if !os(tvOS)
                .refreshable { await load() }
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
        if connectedSources.isEmpty {
            AetherEmptyState(
                glyph: "sparkles",
                title: "Nothing to discover yet",
                message: "Connect a source and Discover surfaces titles you might have forgotten about."
            )
        } else if let loadError, isEmpty {
            AetherErrorState(
                title: "Couldn't build Discover",
                message: loadError,
                retry: .init { Task { await load() } }
            )
        } else if isLoading && isEmpty {
            AetherLoadingState(.rails(count: 2))
                .padding(.top, AetherDesign.Spacing.l)
        } else if isEmpty {
            AetherEmptyState(
                glyph: "tray",
                title: "Library is empty",
                message: "Add some movies or shows to a connected source and they'll surface here."
            )
        } else {
            rails
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
                if let hero {
                    heroSection(hero)
                }
                if !randomPicks.isEmpty {
                    rail(title: "Random Picks", items: randomPicks)
                }
                if !recentlyAdded.isEmpty {
                    rail(title: "Recently Added", items: recentlyAdded)
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
            AetherSectionHeader(title: "Discover")

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

    private func load() async {
        loadError = nil

        guard !connectedSources.isEmpty else {
            hero = nil; randomPicks = []; recentlyAdded = []
            isLoading = false
            return
        }

        isLoading = true
        defer { isLoading = false }

        let library = UnifiedLibrary(sources: connectedSources, downloads: downloadStore)
        let movies = await library.unifiedItems(kind: .movie)
        let shows = await library.unifiedItems(kind: .show)
        let all = movies + shows

        guard !all.isEmpty else {
            hero = nil; randomPicks = []; recentlyAdded = []
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

        // Warm the artwork cache for the rails we're about to show.
        AetherImageCache.shared.prefetch(
            [pick?.backdropURL ?? pick?.posterURL]
                + randomPicks.map(\.posterURL)
                + recentlyAdded.map(\.posterURL)
        )
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
