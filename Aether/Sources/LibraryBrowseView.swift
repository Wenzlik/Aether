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

    @State private var rails: UnifiedRails = .empty
    @State private var isLoading = false
    /// `true` once at least one `load()` has completed. Distinguishes "empty
    /// because we haven't loaded yet" (→ loading) from "loaded and genuinely
    /// empty" (→ empty state), so a refresh never flashes the empty state.
    @State private var hasLoaded = false
    @State private var loadError: String?
    /// One automatic retry on an empty result (transient first-load), so the
    /// library self-heals instead of sticking on an empty state.
    @State private var autoRetried = false
    /// Reload (non-destructively) when the app returns to the foreground.
    @Environment(\.scenePhase) private var scenePhase

    /// When non-empty, the library swaps its rails for unified `MediaSearchResults`.
    @State private var searchQuery = ""
    /// Owns keyboard focus so tapping outside / scrolling / selecting a result
    /// dismisses the keyboard.
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if shouldShowBrandedChrome {
                    VStack(spacing: 0) {
                        brandedHeader
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
                case .genres:
                    GenreListView(connectedSources: connectedSources)
                case .genre(let name):
                    GenreGridView(genre: name, connectedSources: connectedSources, downloadStore: downloadStore)
                }
            }
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

    /// Show the centered Aether lockup + search field above content on the
    /// rails and during search. The empty / no-source / loading / error states
    /// own their own full-screen layout, so the header sits out for those.
    private var shouldShowBrandedChrome: Bool {
        if isSearching { return true }
        if connectedSources.isEmpty { return false }
        if loadError != nil, rails.isEmpty { return false }
        if isLoading && rails.isEmpty { return false }
        if rails.isEmpty { return false }
        return true
    }

    /// Compact nav header (0.6.0): brand mark inline at the leading edge beside
    /// the search field — less wasted vertical space than the old centered banner.
    private var brandedHeader: some View {
        HStack(spacing: AetherDesign.Spacing.m) {
            AetherWordmark(.small)
            AetherSearchField(text: $searchQuery, prompt: "Search your library", focus: $searchFocused)
            #if os(tvOS)
            AetherTVReloadButton { Task { await load() } }
                .frame(width: 260)
            #endif
        }
        .padding(.horizontal, AetherDesign.Spacing.l)
        .padding(.top, AetherDesign.Spacing.l)
        .padding(.bottom, AetherDesign.Spacing.m)
    }

    /// True when the user has typed something — rails get replaced with unified
    /// search results.
    private var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var content: some View {
        if isSearching {
            // Unified search across every connected source (same as Home / Search).
            MediaSearchResults(sources: connectedSources, query: searchQuery)
        } else if !rails.isEmpty {
            // Have content → always show it, including while a refresh runs (so a
            // pull-to-refresh never blanks to an empty/loading state).
            #if os(tvOS)
            // tvOS browses by **category** (Movies / TV Shows / …), not poster
            // rails: Down from Search lands cleanly on the first category instead
            // of skipping into the middle of a rail, and each category opens the
            // full grid. The list is data-driven, so a new content group appears
            // automatically (#266 Detail Phase 1 — tvOS Library nav).
            categoryListContent
            #else
            railsContent
            #endif
        } else if connectedSources.isEmpty {
            // Empty sources: "still connecting" during startup → loading; only
            // once startup has settled is it genuinely "no source connected".
            if isConnecting {
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
        } else if let loadError {
            AetherCenteredScrollState {
                AetherErrorState(
                    title: "Couldn't load your library",
                    message: loadError,
                    retry: .init { Task { await load() } }
                )
            }
        } else if isLoading || !hasLoaded {
            // Loading, or first load not finished yet → branded loader (never empty).
            AetherCenteredScrollState {
                AetherLoadingDots(caption: "Loading your library…")
            }
        } else {
            // Loaded, connected, and genuinely empty — centered + pull-to-refreshable.
            AetherCenteredScrollState {
                AetherEmptyState(
                    glyph: "tray",
                    title: "Library is empty",
                    message: "Add some movies or shows to a connected source and they'll surface here."
                )
            }
        }
    }

    // MARK: - Rails

    /// Library is the **collection browser**: the full deduplicated catalog by
    /// kind, each with a count and a "See all" grid (sort + genre filter live
    /// there). Continue Watching / Recently Added are watch-now surfaces — they
    /// live on Home, not here.
    private var railsContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                if !rails.movies.isEmpty {
                    unifiedRail(title: "Movies", count: rails.movieCount, kind: .movie, items: rails.movies)
                }
                if !rails.shows.isEmpty {
                    unifiedRail(title: "TV Shows", count: rails.showCount, kind: .show, items: rails.shows)
                }
                if hasAnyDownloads {
                    downloadedRail
                }
            }
            .padding(.top, AetherDesign.Spacing.l)
            .padding(.bottom, AetherDesign.Spacing.xxl)
        }
    }

    #if os(tvOS)
    // MARK: - tvOS category list

    /// The content groups present in the library — **data-driven**: a row appears
    /// only for a kind that actually has titles, so a future content group shows
    /// up here automatically without touching this view. Each opens the full grid.
    private var libraryCategories: [(kind: MediaItem.Kind, title: String, count: Int)] {
        var cats: [(MediaItem.Kind, String, Int)] = []
        if !rails.movies.isEmpty { cats.append((.movie, "Movies", rails.movieCount)) }
        if !rails.shows.isEmpty { cats.append((.show, "TV Shows", rails.showCount)) }
        return cats.map { (kind: $0.0, title: $0.1, count: $0.2) }
    }

    /// tvOS Library landing: big focusable category rows under the search field,
    /// each pushing the full unified grid for that kind. Replaces the poster rails
    /// so D-pad Down from Search moves predictably down the categories instead of
    /// skipping into the middle of a rail.
    private var categoryListContent: some View {
        ScrollView {
            LazyVStack(spacing: AetherDesign.Spacing.m) {
                ForEach(libraryCategories, id: \.kind) { category in
                    NavigationLink(value: UnifiedLibrarySection(kind: category.kind, title: category.title)) {
                        categoryRow(title: category.title, count: category.count)
                    }
                    .buttonStyle(.plain)
                }
                // Browse by genre across the whole library (#266). More facets
                // (Years, Collections, …) will join here.
                NavigationLink(value: LibraryBrowseRoute.genres) {
                    LibraryBrowseRow(title: "Genres")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, AetherDesign.Spacing.xl)
            .padding(.top, AetherDesign.Spacing.l)
            .padding(.bottom, AetherDesign.Spacing.xxl)
        }
    }

    /// One category row — title + count + chevron in a card that lifts on focus.
    private func categoryRow(title: String, count: Int) -> some View {
        HStack(spacing: AetherDesign.Spacing.m) {
            Text(title)
                .font(AetherDesign.Typography.sectionTitle)
                .foregroundStyle(AetherDesign.Palette.textPrimary)
            Spacer(minLength: AetherDesign.Spacing.m)
            Text(countLabel(count))
                .font(AetherDesign.Typography.metadata)
                .foregroundStyle(AetherDesign.Palette.textSecondary)
            Image(systemName: "chevron.right")
                .font(.headline)
                .foregroundStyle(AetherDesign.Palette.textTertiary)
        }
        .padding(.horizontal, AetherDesign.Spacing.l)
        .padding(.vertical, AetherDesign.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                .fill(AetherDesign.Materials.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                .strokeBorder(AetherDesign.Palette.separator, lineWidth: 1)
        )
        .premiumFocus()
    }
    #endif

    /// `true` once there's at least one completed download — gates the
    /// Downloaded rail. Management lives in Settings → Downloads; Library only
    /// surfaces them as content.
    private var hasAnyDownloads: Bool {
        !(downloads?.snapshot.completed.isEmpty ?? true)
    }

    /// "Downloaded" rail — completed items, newest first, straight from the
    /// download observer's snapshot (valid offline).
    private var downloadedRail: some View {
        let count = downloads?.snapshot.completed.count ?? 0
        return VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            AetherSectionHeader(title: "Downloads", subtitle: countLabel(count))

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: AetherDesign.Spacing.l) {
                    ForEach(downloads?.snapshot.completed ?? []) { job in
                        downloadedCard(job)
                    }
                }
                .padding(.horizontal, AetherDesign.Spacing.l)
                .padding(.vertical, AetherDesign.Spacing.xs)
            }
            .aetherFocusSection()
        }
    }

    /// Card for a downloaded job. Rendered from the job's captured snapshot
    /// (title + poster + episode context) so it reads correctly offline.
    /// Tapping pushes a `MediaItem` that `mediaNavigationDestinations` routes.
    private func downloadedCard(_ job: DownloadJob) -> some View {
        let item = MediaItem(
            id: job.mediaID,
            title: job.title,
            kind: job.kind,
            posterURL: job.displayPosterURL,
            seriesTitle: job.seriesTitle,
            seasonNumber: job.seasonNumber,
            episodeNumber: job.episodeNumber
        )

        return NavigationLink(value: item) {
            AetherCard.poster(title: item.displayTitle, posterURL: item.posterURL, isWatched: item.isFullyWatched)
                .frame(width: posterWidth)
        }
        .buttonStyle(.plain)
    }

    /// A unified poster rail (Movies / TV Shows) with a title count and a
    /// "See all" that pushes the full grid for that kind.
    private func unifiedRail(title: String, count: Int, kind: MediaItem.Kind, items: [UnifiedMediaItem]) -> some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            AetherSectionHeader(
                title: title,
                subtitle: countLabel(count),
                accessoryTitle: "See all",
                accessoryAction: { @MainActor in
                    navigationPath.append(UnifiedLibrarySection(kind: kind, title: title))
                }
            )
            // tvOS: make the header row a full-width focus section so Up from
            // *any* poster (not just the last one) lands on its single focusable
            // — the "See all" Button — without scrolling to the rail's end (#249
            // follow-up). Full-width ⇒ overlaps every column; the title/subtitle
            // are plain Text, so See-all is the lone cross-axis match. No-op off tvOS.
            .frame(maxWidth: .infinity)
            .aetherHeaderFocusSection()

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: AetherDesign.Spacing.l) {
                    ForEach(items.prefix(12)) { item in
                        NavigationLink(value: item) {
                            AetherCard.poster(title: item.title, posterURL: item.posterURL, isWatched: item.isFullyWatched)
                                .frame(width: posterWidth)
                        }
                        .buttonStyle(.plain)
                    }

                    // Prominent, focusable "See all" tile at the end of the rail
                    // (Apple-TV pattern) — far more visible than the header link,
                    // and reliably reachable by focus on tvOS.
                    if items.count > 12 {
                        NavigationLink(value: UnifiedLibrarySection(kind: kind, title: title)) {
                            seeAllCard
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, AetherDesign.Spacing.l)
                .padding(.vertical, AetherDesign.Spacing.xs)
            }
            .aetherFocusSection()
        }
    }

    /// The trailing "See all" tile — poster-sized so it sits flush in the rail.
    private var seeAllCard: some View {
        VStack(spacing: AetherDesign.Spacing.s) {
            Image(systemName: "arrow.forward.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(AetherDesign.Palette.accent)
            Text("See all")
                .font(AetherDesign.Typography.cardTitle)
                .foregroundStyle(AetherDesign.Palette.textPrimary)
        }
        .frame(width: posterWidth)
        .frame(maxHeight: .infinity)
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .background(
            RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                .fill(AetherDesign.Materials.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                .strokeBorder(AetherDesign.Palette.separator, lineWidth: 1)
        )
    }

    // MARK: - Sizing

    private var posterWidth: CGFloat {
        #if os(tvOS)
        300
        #else
        140
        #endif
    }

    /// "1 title" / "248 titles" — the count shown beneath a section header.
    private func countLabel(_ count: Int) -> String {
        "\(count) title\(count == 1 ? "" : "s")"
    }

    // MARK: - Loading

    private func load(forceRefresh: Bool = false) async {
        loadError = nil
        defer { hasLoaded = true }
        guard !connectedSources.isEmpty else {
            rails = .empty
            return
        }
        isLoading = true
        defer { isLoading = false }
        let library = UnifiedLibrary(sources: connectedSources, downloads: downloadStore)
        let built = await library.homeRails(resumeStore: resumeStore, forceRefresh: forceRefresh)
        if built.isEmpty, !rails.isEmpty {
            // A refresh came back empty but we already have content — almost always
            // a transient source hiccup. Keep the current library on screen instead
            // of flashing "Library is empty", and retry once.
            scheduleAutoRetryIfNeeded()
        } else {
            rails = built
            AetherImageCache.shared.prefetch(
                built.movies.map(\.posterURL) + built.shows.map(\.posterURL)
            )
            if built.isEmpty { scheduleAutoRetryIfNeeded() } else { autoRetried = false }
        }
        // Stale-while-revalidate (#197): a cold launch paints the persisted
        // snapshot instantly; refresh silently if it's past the 1-hour window.
        if !forceRefresh, !built.isEmpty {
            let staleMovies = await library.isStale(kind: .movie)
            let staleShows = await library.isStale(kind: .show)
            if staleMovies || staleShows { Task { await load(forceRefresh: true) } }
        }
    }

    /// One automatic retry when a connected source returns empty (often a
    /// transient first-load), so the library self-heals instead of sticking.
    /// Bounded by `autoRetried`; pull-to-refresh + foreground reload cover more.
    private func scheduleAutoRetryIfNeeded() {
        guard !autoRetried, !connectedSources.isEmpty else { return }
        autoRetried = true
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, rails.isEmpty else { return }
            await load(forceRefresh: true)
        }
    }
}

/// "See all" push target — a full unified grid for one media kind.
struct UnifiedLibrarySection: Hashable {
    let kind: MediaItem.Kind
    let title: String
}

private extension View {
    /// Apply `.focusSection()` on tvOS for predictable D-pad movement between
    /// rails; no-op elsewhere (the API is tvOS-only).
    @ViewBuilder
    func aetherFocusSection() -> some View {
        #if os(tvOS)
        self.focusSection()
        #else
        self
        #endif
    }

    /// Mark a rail's *header row* as its own focus section on tvOS so Up from any
    /// poster reliably lands on the header's single focusable ("See all"). Same
    /// shape as `aetherFocusSection()`; no-op elsewhere.
    @ViewBuilder
    func aetherHeaderFocusSection() -> some View {
        #if os(tvOS)
        self.focusSection()
        #else
        self
        #endif
    }

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
