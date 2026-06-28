import SwiftUI
import AetherCore

/// The Library tab root — Aether's browse hub, now **unified** across every
/// connected source.
///
/// The source is an implementation detail here too: one deduplicated catalog,
/// not a per-server picker. Layout:
/// - a branded hero header ("Aether" + search field),
/// - a Downloaded rail (when there are downloads),
/// - a Continue Watching rail (cross-source, best resume per title),
/// - **Movies** and **TV Shows** rails, each with a "See all" link that pushes a
///   full unified grid (`UnifiedLibraryGridView`).
///
/// Reuses `UnifiedLibrary.homeRails(...)` — the same aggregator Home uses — so
/// the data layer isn't duplicated. Cards navigate `UnifiedMediaItem`, so Detail
/// shows the title's Available Sources.
struct LibraryBrowseView: View {
    /// Lifted from `RootTabView` so re-selecting the Library tab can pop to root.
    @Binding var navigationPath: NavigationPath
    /// Every connected source — aggregated + deduplicated by `UnifiedLibrary`.
    let connectedSources: [any MediaSource]
    /// `true` while `AppSession` is still starting up / discovering. An empty
    /// `connectedSources` then means "still connecting" → show loading, not the
    /// "connect a source" empty state.
    let isConnecting: Bool
    /// Backs the unified aggregator's offline fold-in.
    let downloadStore: DownloadStore?
    let resumeStore: ResumeStore
    let playbackSession: PlaybackSession
    let libraryPreferences: LibraryPreferencesStore
    let onAddSource: () -> Void
    /// Forwarded to `mediaNavigationDestinations` so Detail can wire the
    /// Download button. Optional — `nil` before `AppSession.start()`.
    let downloadManager: DownloadManager?
    let downloads: DownloadObserver?
    /// Forwarded so DetailView can seed Audio / Subtitle / Quality pickers
    /// from the user's Settings defaults.
    let playbackPreferences: PlaybackPreferencesStore?

    @Environment(WatchAvailabilityStore.self) private var availability: WatchAvailabilityStore?

    /// When non-empty, the library swaps its grid for unified `MediaSearchResults`.
    @State private var searchQuery = ""
    /// iOS / visionOS: header shows a search *button* by default; the field only
    /// appears once tapped — no permanent search bar (matches Home).
    @State private var isSearchActive = false
    /// Ask Aether answer (library matches + optional recommendation), shown after
    /// the user submits a request. Sticky while refining; dropped when cleared.
    /// Same behaviour as the Search tab (see `AskAether`).
    @State private var askResult: AskResult?
    /// On-device inference in flight.
    @State private var isAsking = false
    /// Owns keyboard focus so tapping outside / scrolling / selecting a result
    /// dismisses the keyboard.
    @FocusState private var searchFocused: Bool
    #if os(iOS)
    /// iPad (regular) vs iPhone (compact) — drives whether the brand + search +
    /// filter ride the top tab-bar row (parity with Home #370) or stay inline.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if shouldShowBrandedChrome {
                    VStack(spacing: 0) {
                        // iPad (regular): brand + search + filter ride the top
                        // tab-bar row as toolbar items (parity with Home #370);
                        // only the search field drops to a slim row while active.
                        // iPhone / visionOS / tvOS keep the inline header.
                        #if os(iOS)
                        if usesTopBarChrome {
                            if isSearchActive { iPadSearchRow }
                        } else {
                            brandedHeader
                        }
                        #else
                        brandedHeader
                        #endif
                        content
                            .dismissSearchKeyboardOnTap { searchFocused = false }
                    }
                } else {
                    content
                }
            }
            // `scrollDismissesKeyboard` is unavailable on visionOS; tap-outside
            // + Search/Done still dismiss there.
            #if os(iOS)
            .scrollDismissesKeyboard(.immediately)
            #endif
            .aetherScreenBackground()
            // Return in any search field submits an Ask Aether request; clearing
            // the field drops the answer (back to the grid).
            .onSubmit { Task { await ask() } }
            .onChange(of: searchQuery) { _, newValue in
                if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { askResult = nil }
            }
            // Pull-to-refresh + reload now live in the grid itself; the shell no
            // longer fetches rails of its own.
            // iPad: brand (leading, flush) + Filter + Search (trailing) on the
            // top tab-bar row instead of a second header band.
            #if os(iOS)
            .toolbar { if usesTopBarChrome && shouldShowBrandedChrome { libraryTopBarItems } }
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
            // "See all" → full unified grid for a kind.
            .navigationDestination(for: UnifiedLibrarySection.self) { section in
                UnifiedLibraryGridView(
                    title: section.title,
                    kind: section.kind,
                    connectedSources: connectedSources,
                    downloadStore: downloadStore
                )
            }
            // Browse facets (Genres, …) — the richer Library hierarchy (#266).
            .navigationDestination(for: LibraryBrowseRoute.self) { route in
                switch route {
                case .allTitles:
                    UnifiedLibraryGridView(
                        title: "Library",
                        kind: nil,
                        connectedSources: connectedSources,
                        downloadStore: downloadStore,
                        autoOpenFilter: true
                    )
                case .genres:
                    GenreListView(connectedSources: connectedSources)
                case .genre(let name):
                    FacetGridView(title: name, connectedSources: connectedSources, downloadStore: downloadStore) {
                        $0.genres.contains(name)
                    }
                case .years:
                    YearListView(connectedSources: connectedSources)
                case .year(let year):
                    FacetGridView(title: String(year), connectedSources: connectedSources, downloadStore: downloadStore) {
                        $0.year == year
                    }
                case .collections:
                    CollectionListView(connectedSources: connectedSources)
                case .collection(let entry):
                    SourceFacetGridView(title: entry.title, downloadStore: downloadStore) { [connectedSources] in
                        await collectionItems(for: entry, sources: connectedSources)
                    }
                case .actors:
                    PersonListView(kind: .actor, connectedSources: connectedSources)
                case .directors:
                    PersonListView(kind: .director, connectedSources: connectedSources)
                case .person(let entry):
                    SourceFacetGridView(title: entry.name, downloadStore: downloadStore) { [connectedSources] in
                        await personItems(for: entry, sources: connectedSources)
                    }
                }
            }
        }
    }

    /// Show the centered Aether lockup + search field above content on the
    /// rails and during search. The empty / no-source / loading / error states
    /// own their own full-screen layout, so the header sits out for those.
    private var shouldShowBrandedChrome: Bool {
        // Searching → header carries the field; connected → header sits above the
        // combined grid. Only the no-source / connecting state owns the full
        // screen (the grid renders its own loading / empty states).
        if isSearching { return true }
        return !connectedSources.isEmpty
    }

    /// Compact nav header (0.6.0): brand mark inline at the leading edge beside
    /// the search field — less wasted vertical space than the old centered banner.
    private var brandedHeader: some View {
        HStack(spacing: AetherDesign.Spacing.m) {
            #if os(tvOS)
            AetherWordmark(.medium)
            Spacer(minLength: AetherDesign.Spacing.l)
            AetherSearchField(text: $searchQuery, prompt: "Ask Aether…", focus: $searchFocused)
                .frame(maxWidth: AetherDesign.headerSearchWidth)
            // Reload moved into the grid's bar (it owns loading now).
            #else
            if isSearchActive {
                AetherSearchField(text: $searchQuery, prompt: "Ask Aether…", focus: $searchFocused)
                Button("Cancel") {
                    searchQuery = ""
                    searchFocused = false
                    isSearchActive = false
                }
                .buttonStyle(.plain)
                .foregroundStyle(AetherDesign.Palette.accent)
            } else {
                AetherWordmark(.medium)
                Spacer(minLength: AetherDesign.Spacing.l)
                // Top-right is Search only (#383) — browse facets now live in the
                // pill row in the content; filtering happens inside each grid.
                searchButton
            }
            #endif
        }
        .padding(.horizontal, AetherDesign.Spacing.l)
        .padding(.top, AetherDesign.Spacing.l)
        .padding(.bottom, AetherDesign.Spacing.m)
    }

    // MARK: - Search

    #if !os(tvOS)
    /// Top-right magnifying-glass that reveals the search field.
    private var searchButton: some View {
        Button {
            isSearchActive = true
            searchFocused = true
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.title3.weight(.semibold))
                .foregroundStyle(AetherDesign.Palette.textPrimary)
                .frame(width: 44, height: 44)
                .background(AetherDesign.Palette.surface, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search")
    }
    #endif

    // MARK: - iPad top-bar chrome (parity with Home #370)

    /// iPad regular width — brand + filter + search ride the top tab-bar row.
    /// False on iPhone (compact, keeps the inline header) and visionOS / tvOS.
    private var usesTopBarChrome: Bool {
        #if os(iOS)
        horizontalSizeClass == .regular
        #else
        false
        #endif
    }

    #if os(iOS)
    @ToolbarContentBuilder
    private var libraryTopBarItems: some ToolbarContent {
        // Top-right is Search only (#383) — browse facets live in the pill row in
        // the content, and filtering happens inside each grid.
        if !isSearchActive {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isSearchActive = true
                    searchFocused = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("Search")
            }
        }
    }

    /// iPad: the slim search-field row shown only while searching (the brand +
    /// Filter + search button live in the tab-bar toolbar).
    private var iPadSearchRow: some View {
        HStack(spacing: AetherDesign.Spacing.m) {
            AetherSearchField(text: $searchQuery, prompt: "Ask Aether…", focus: $searchFocused)
            Button("Cancel") {
                searchQuery = ""
                searchFocused = false
                isSearchActive = false
            }
            .buttonStyle(.plain)
            .foregroundStyle(AetherDesign.Palette.accent)
        }
        .padding(.horizontal, AetherDesign.Spacing.l)
        .padding(.top, AetherDesign.Spacing.s)
        .padding(.bottom, AetherDesign.Spacing.m)
    }
    #endif

    /// True when the user has typed something — rails get replaced with unified
    /// search results.
    private var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Ask Aether from Library — find titles + recommend. Mirrors the Search tab.
    private func ask() async {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !connectedSources.isEmpty, !isAsking else { return }
        searchFocused = false
        isAsking = true
        defer { isAsking = false }
        let answer = await AskAether.answer(query: trimmed, sources: connectedSources)
        guard searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
        askResult = answer
    }

    /// Edited-but-not-resubmitted request → "press Return to ask" hint.
    private var askPending: String? {
        guard let askResult else { return nil }
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return (!trimmed.isEmpty && trimmed != askResult.query) ? trimmed : nil
    }

    @ViewBuilder
    private var content: some View {
        if isAsking {
            AetherLoadingDots(caption: "Asking Aether…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let askResult {
            RecommendationResultsView(result: askResult, pendingQuery: askPending)
        } else if isSearching {
            // Live title search while typing, before an ask.
            MediaSearchResults(sources: connectedSources, query: searchQuery)
        } else if !connectedSources.isEmpty {
            // Unified Library landing: one combined grid (Movies + TV Shows) with
            // a persistent Movies/Series toggle, filters, and browse pills — no
            // more per-kind rails + "See all". Shown whenever a source is
            // configured, even offline, so the Downloaded filter stays reachable;
            // the grid owns its own loading / empty / offline states.
            UnifiedLibraryGridView(
                title: "Library",
                kind: nil,
                connectedSources: connectedSources,
                downloadStore: downloadStore,
                isLibraryRoot: true,
                downloads: downloads
            )
        } else if isConnecting {
            AetherCenteredScrollState {
                AetherLoadingDots(caption: "Loading your library…")
            }
        } else {
            AetherCenteredScrollState {
                AetherEmptyState(
                    glyph: "rectangle.stack",
                    title: "No library yet",
                    message: "Connect a source and your Aether library appears here.",
                    action: .init(label: "Add a source", run: onAddSource)
                )
            }
        }
    }

}

/// "See all" push target — a full unified grid for one media kind.
struct UnifiedLibrarySection: Hashable {
    let kind: MediaItem.Kind
    let title: String
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
