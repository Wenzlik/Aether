import SwiftUI
import AetherCore

/// **Search** — a first-class tab on every platform.
///
/// Search used to live only as an inline field on Home / Library. Promoting it
/// to its own tab gives it a permanent home in the tab bar (the pattern Music /
/// TV+ use) and a calm, centered entry point: the Aether lockup, a single search
/// field, and unified results beneath it.
///
/// Results come from `MediaSearchResults`, which searches **across every
/// connected source** and returns deduplicated `UnifiedMediaItem`s — so a title
/// on both Plex and Jellyfin appears once, and Detail gets its full source list.
struct SearchView: View {
    /// Every connected source — searched together, results merged + deduped.
    let connectedSources: [any MediaSource]
    /// The single active source — still threaded through
    /// `mediaNavigationDestinations` for `LibraryView` drill-ins.
    let source: (any MediaSource)?
    let resumeStore: ResumeStore
    let playbackSession: PlaybackSession
    let libraryPreferences: LibraryPreferencesStore
    let downloadManager: DownloadManager?
    let downloads: DownloadObserver?
    let playbackPreferences: PlaybackPreferencesStore?

    @State private var query = ""
    @State private var navigationPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navigationPath) {
            VStack(spacing: 0) {
                header
                content
            }
            .background(AetherDesign.Gradients.background.ignoresSafeArea())
            .mediaNavigationDestinations(
                source: source,
                connectedSources: connectedSources,
                resumeStore: resumeStore,
                playbackSession: playbackSession,
                libraryPreferences: libraryPreferences,
                downloadManager: downloadManager,
                downloads: downloads,
                playbackPreferences: playbackPreferences
            )
        }
    }

    /// Centered Aether mark + search field — mirrors Home's branded header so
    /// the two tabs feel like one family.
    private var header: some View {
        VStack(spacing: AetherDesign.Spacing.m) {
            AetherWordmark(.large)
                .frame(maxWidth: .infinity)
            AetherSearchField(text: $query, prompt: "Search your library")
        }
        .padding(.horizontal, AetherDesign.Spacing.l)
        .padding(.top, AetherDesign.Spacing.l)
        .padding(.bottom, AetherDesign.Spacing.m)
    }

    @ViewBuilder
    private var content: some View {
        if isSearching {
            MediaSearchResults(sources: connectedSources, query: query)
        } else {
            AetherEmptyState(
                glyph: "magnifyingglass",
                title: "Search your library",
                message: "Find a movie or show across every connected source — start typing above."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
