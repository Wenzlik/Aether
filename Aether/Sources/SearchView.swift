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

    @Environment(WatchAvailabilityStore.self) private var availability: WatchAvailabilityStore?
    @Environment(AppSession.self) private var appSession

    @State private var query = ""
    /// Owns keyboard focus so taps outside the field, scrolling the results, or
    /// selecting a result all dismiss the keyboard — the native search feel.
    @FocusState private var searchFocused: Bool

    /// Discovery rails shown before the user types, so Search never looks like a
    /// blank page. Same unified data Home builds from.
    @State private var discovery: UnifiedRails = .empty
    @State private var isLoadingDiscovery = false
    @State private var hasLoadedDiscovery = false
    /// Recent submitted queries, shown as tappable chips before typing.
    @State private var recentSearches = RecentSearchesStore()

    /// The latest "Ask Aether" answer — library matches plus an optional
    /// recommendation. Sticky while the user refines (press Return to re-ask);
    /// dropped when the field is cleared. Live title search applies only to fresh
    /// typing before the first ask.
    @State private var askResult: AskResult?
    /// On-device inference in flight.
    @State private var isAsking = false

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
            .task(id: sourcesKey) { await loadDiscovery() }
            // Keep the recommendation visible while the user refines the request
            // (they press Return to re-ask); only drop it when the field is
            // cleared, which returns to discovery. Live title search is for fresh
            // typing before an ask — not for editing an existing recommendation.
            .onChange(of: query) { _, newValue in
                if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    askResult = nil
                }
            }
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

    /// Compact nav header — brand mark inline beside the search field, mirroring
    /// Home / Library so the tabs read as one family (0.6.0).
    private var header: some View {
        HStack(spacing: AetherDesign.Spacing.m) {
            AetherWordmark(.small)
            AetherSearchField(text: $query, prompt: "Ask Aether…", focus: $searchFocused)
                .onSubmit {
                    recentSearches.record(query)
                    Task { await ask() }
                }
        }
        .padding(.horizontal, AetherDesign.Spacing.l)
        .padding(.top, AetherDesign.Spacing.l)
        .padding(.bottom, AetherDesign.Spacing.m)
    }

    @ViewBuilder
    private var content: some View {
        if isAsking {
            AetherLoadingDots(caption: String(localized: "Asking Aether…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let askResult {
            RecommendationResultsView(result: askResult, pendingQuery: pendingAsk)
        } else if isSearching {
            MediaSearchResults(sources: connectedSources, query: query)
        } else {
            discoveryContent
        }
    }

    /// Pre-typing state — alive, not blank: discovery rails from the unified
    /// library. Degrades gracefully (no source / still loading / nothing found).
    @ViewBuilder
    private var discoveryContent: some View {
        if connectedSources.isEmpty {
            AetherEmptyState(
                glyph: "sparkles",
                title: "Ask Aether",
                message: "Connect a source, then ask for something to watch — or find a title by name."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if discoveryIsEmpty && (isLoadingDiscovery || !hasLoadedDiscovery) {
            AetherLoadingState(.rails(count: 2))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                    if !recentSearches.recent.isEmpty {
                        recentSearchesSection
                    }
                    if !discovery.recentlyAdded.isEmpty {
                        rail(title: "Recently Added", items: discovery.recentlyAdded)
                    }
                    if !discovery.recentlyReleased.isEmpty {
                        rail(title: "Recently Released", items: discovery.recentlyReleased)
                    }
                    if recentSearches.recent.isEmpty && discoveryIsEmpty {
                        AetherEmptyState(
                            glyph: "sparkles",
                            title: "Ask Aether",
                            message: "Ask for something to watch — “a scary movie under 2 hours” — or find a title by name."
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, AetherDesign.Spacing.xl)
                    }
                }
                .padding(.vertical, AetherDesign.Spacing.l)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Recent submitted queries as tappable chips, with a Clear affordance.
    /// Tapping a chip re-runs that search.
    private var recentSearchesSection: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            HStack {
                AetherSectionHeader(title: "Recent")
                Spacer(minLength: AetherDesign.Spacing.s)
                Button("Clear") { recentSearches.clear() }
                    .font(AetherDesign.Typography.metadata)
                    .foregroundStyle(AetherDesign.Palette.accent)
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, AetherDesign.Spacing.l)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AetherDesign.Spacing.s) {
                    ForEach(recentSearches.recent, id: \.self) { recentQuery in
                        Button {
                            // Recent entries are "Ask Aether" requests, so tapping
                            // one re-runs the recommendation (not a title search).
                            query = recentQuery
                            Task { await ask() }
                        } label: {
                            Text(recentQuery)
                                .font(AetherDesign.Typography.metadata)
                                .foregroundStyle(AetherDesign.Palette.textPrimary)
                                .padding(.horizontal, AetherDesign.Spacing.m)
                                .padding(.vertical, AetherDesign.Spacing.s)
                                .background(AetherDesign.Materials.card, in: Capsule())
                                .overlay { Capsule().strokeBorder(AetherDesign.Palette.separator, lineWidth: 1) }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, AetherDesign.Spacing.l)
            }
        }
    }

    /// Horizontal poster rail — mirrors Discover/Home so the tabs read as one
    /// family (shared rail extraction is tracked as a consistency follow-up).
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
        }
    }

    private var posterWidth: CGFloat {
        #if os(tvOS)
        300
        #else
        168
        #endif
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The edited-but-not-yet-submitted request, when the field no longer matches
    /// the shown recommendation — drives the "press Return to ask again" hint.
    private var pendingAsk: String? {
        guard let askResult else { return nil }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return (!trimmed.isEmpty && trimmed != askResult.query) ? trimmed : nil
    }

    private var discoveryIsEmpty: Bool {
        discovery.recentlyAdded.isEmpty && discovery.recentlyReleased.isEmpty
    }

    private var sourcesKey: String {
        connectedSources.map { $0.id.stableKey }.sorted().joined(separator: ",")
    }

    /// Run an "Ask Aether" request: fetch the unified catalogue and hand it to
    /// the concierge (on-device model where available, deterministic fallback
    /// otherwise). Guards against a stale result if the user keeps typing.
    private func ask() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !connectedSources.isEmpty, !isAsking else { return }
        searchFocused = false
        isAsking = true
        defer { isAsking = false }

        let answer = await AskAether.answer(query: trimmed, sources: connectedSources, tmdb: appSession.tmdbClient)

        // The user may have edited the field while inference ran — only keep the
        // answer if it still matches what's in the box.
        guard query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
        askResult = answer
    }

    private func loadDiscovery() async {
        defer { hasLoadedDiscovery = true }
        guard !connectedSources.isEmpty else {
            discovery = .empty
            return
        }
        isLoadingDiscovery = true
        defer { isLoadingDiscovery = false }
        let library = UnifiedLibrary(sources: connectedSources, downloads: nil)
        discovery = await library.homeRails(resumeStore: resumeStore)
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
