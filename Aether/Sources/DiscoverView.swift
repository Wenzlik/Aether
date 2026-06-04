#if os(tvOS)
import SwiftUI
import AetherCore

/// **Discover** — the tvOS-exclusive content tab.
///
/// Replaces the Storage tab on Apple TV (Storage is a download manager;
/// Apple TV doesn't get downloads). Surfaces a curated *find-something-
/// new* experience on top of the user's existing library:
///
/// - **Hero pick** — a single big artwork at the top, randomly drawn
///   from across every library on each build. Reads as the "Featured"
///   slot the user expects from Apple TV / Disney+, but the pick is
///   the *user's own* library, not editorial recommendations.
/// - **Random Picks** — a horizontal rail of 12 shuffled titles. The
///   point isn't novelty for novelty's sake — it's helping the user
///   rediscover titles they own but forgot about.
/// - **Recently Added** — a horizontal rail interleaving each
///   library's newest items round-robin so every library gets surfaced.
///
/// The feed builds once per appearance (cached for the session). The
/// shuffle is intentionally re-rolled per build so a user who keeps
/// returning to Discover sees different picks across the week.
struct DiscoverView: View {
    let source: (any MediaSource)?
    let resumeStore: ResumeStore
    let playbackSession: PlaybackSession
    let libraryPreferences: LibraryPreferencesStore
    let downloadManager: DownloadManager?
    let downloads: DownloadObserver?
    let playbackPreferences: PlaybackPreferencesStore?

    @State private var feed: DiscoverFeed = .empty
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var navigationPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navigationPath) {
            content
                .background(AetherDesign.Gradients.background.ignoresSafeArea())
                .mediaNavigationDestinations(
                    source: source,
                    resumeStore: resumeStore,
                    playbackSession: playbackSession,
                    libraryPreferences: libraryPreferences,
                    downloadManager: downloadManager,
                    downloads: downloads,
                    playbackPreferences: playbackPreferences
                )
        }
        .task(id: source?.id) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if source == nil {
            AetherEmptyState(
                glyph: "sparkles",
                title: "Nothing to discover yet",
                message: "Connect a source and Discover surfaces titles you might have forgotten about."
            )
        } else if let loadError, feed.isEmpty {
            AetherErrorState(
                title: "Couldn't build Discover",
                message: loadError,
                retry: .init { Task { await load() } }
            )
        } else if isLoading && feed.isEmpty {
            AetherLoadingState(.rails(count: 2))
                .padding(.top, AetherDesign.Spacing.l)
        } else if feed.isEmpty {
            AetherEmptyState(
                glyph: "tray",
                title: "Library is empty",
                message: "Add some movies or shows to the connected source and they'll surface here."
            )
        } else {
            rails
        }
    }

    private var rails: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                if let hero = feed.heroPick {
                    heroSection(hero)
                }
                if !feed.randomPicks.isEmpty {
                    rail(title: "Random Picks", items: feed.randomPicks)
                }
                if !feed.recentlyAdded.isEmpty {
                    rail(title: "Recently Added", items: feed.recentlyAdded)
                }
            }
            .padding(.bottom, AetherDesign.Spacing.xxl)
        }
    }

    // MARK: - Sections

    /// A wide single-card hero showing one randomly-picked title, tappable
    /// straight into Detail. Echoes the Featured row Home shows, but
    /// hero is intentionally a *single* artwork (not a horizontal rail)
    /// so the random pick reads as "this is the title we're suggesting,"
    /// not "here are some options."
    private func heroSection(_ item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            AetherSectionHeader(title: "Discover")

            NavigationLink(value: item) {
                AetherCard.hero(
                    title: item.title,
                    subtitle: item.year.map(String.init),
                    posterURL: item.backdropURL ?? item.posterURL
                )
                .frame(maxWidth: .infinity)
                .frame(height: 480)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, AetherDesign.Spacing.l)
        }
    }

    /// Generic horizontal poster rail — same composition Home / Library
    /// use, scoped to Discover here so the layout token stays consistent
    /// across tabs.
    private func rail(title: String, items: [MediaItem]) -> some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            AetherSectionHeader(title: title)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: AetherDesign.Spacing.l) {
                    ForEach(items) { item in
                        NavigationLink(value: item) {
                            AetherCard.poster(title: item.title, posterURL: item.posterURL)
                                .frame(width: 300)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, AetherDesign.Spacing.l)
                .padding(.vertical, AetherDesign.Spacing.xs)
            }
            // tvOS-only D-pad section. The file is `#if os(tvOS)` gated,
            // so `focusSection()` is always available — no need for the
            // `aetherFocusSection` cross-platform wrapper HomeView /
            // LibraryBrowseView use (those screens compile on iOS too).
            .focusSection()
        }
    }

    // MARK: - Loading

    private func load() async {
        loadError = nil

        guard let source else {
            feed = .empty
            isLoading = false
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let builder = DiscoverFeedBuilder()
            feed = try await builder.build(source: source)
        } catch {
            feed = .empty
            loadError = error.localizedDescription
        }
    }
}
#endif
