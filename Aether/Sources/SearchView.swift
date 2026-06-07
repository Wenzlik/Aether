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
    /// Lifted from `RootTabView` so re-selecting the Search tab can pop to root.
    @Binding var navigationPath: NavigationPath
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
    /// Owns keyboard focus so taps outside the field, scrolling the results, or
    /// selecting a result all dismiss the keyboard — the native search feel.
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack(path: $navigationPath) {
            VStack(spacing: 0) {
                header
                content
                    // Tap anywhere in the results (empty space or a result) ends
                    // editing; a result tap still navigates. The field lives in
                    // the header, so focusing it isn't caught here. iOS/visionOS
                    // only — see helper.
                    .dismissSearchKeyboardOnTap { searchFocused = false }
                    // `scrollDismissesKeyboard` is unavailable on visionOS;
                    // tap-outside + Search/Done still dismiss there.
                    #if os(iOS)
                    .scrollDismissesKeyboard(.immediately)
                    #endif
            }
            .aetherScreenBackground()
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
            AetherSearchField(text: $query, prompt: "Search your library", focus: $searchFocused)
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

private extension View {
    /// Tap-to-dismiss the search keyboard — iOS / visionOS only. On tvOS there's
    /// no software keyboard, and a `TapGesture` there would intercept the Select
    /// button and disrupt the focus engine, so it's a no-op.
    @ViewBuilder
    func dismissSearchKeyboardOnTap(_ action: @escaping () -> Void) -> some View {
        #if os(iOS) || os(visionOS)
        simultaneousGesture(TapGesture().onEnded(action))
        #else
        self
        #endif
    }
}
