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

    @State private var rails: UnifiedRails = .empty
    @State private var isLoading = false
    /// `true` once at least one `load()` has completed. Distinguishes "empty
    /// because we haven't loaded yet" (→ loading) from "loaded and genuinely
    /// empty" (→ empty state), so a refresh never flashes the empty state.
    @State private var hasLoaded = false
    @State private var loadError: String?
    /// Whether any connected source has **actual** collections — the Collections
    /// browse entry is gated on this, not just on `supportsCollections`. A
    /// Plex-only setup whose server has no collections (common) otherwise showed
    /// a Collections row that led to a dead empty screen (#298/#311).
    @State private var hasCollections = false
    /// One automatic retry on an empty result (transient first-load), so the
    /// library self-heals instead of sticking on an empty state.
    @State private var autoRetried = false
    /// Reload (non-destructively) when the app returns to the foreground.
    @Environment(\.scenePhase) private var scenePhase

    /// When non-empty, the library swaps its rails for unified `MediaSearchResults`.
    @State private var searchQuery = ""
    /// iOS / visionOS: header shows a search *button* by default; the field only
    /// appears once tapped — no permanent search bar (matches Home).
    @State private var isSearchActive = false
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
            #if !os(tvOS)
            .refreshable { await load(forceRefresh: true) }
            #endif
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
        .task(id: sourcesKey) { await load() }
        .task(id: sourcesKey) { await refreshCollectionsAvailability() }
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
            AetherSearchField(text: $searchQuery, prompt: "Search your library", focus: $searchFocused)
                .frame(maxWidth: AetherDesign.headerSearchWidth)
            AetherTVReloadButton { Task { await load() } }
                .frame(width: 260)
            #else
            if isSearchActive {
                AetherSearchField(text: $searchQuery, prompt: "Search your library", focus: $searchFocused)
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
    /// iPad: the brand icon (leading) + Filter + Search (trailing) ride the top
    /// tab-bar row. Brand is the square app icon; tapping it pops Library to root.
    @ToolbarContentBuilder
    private var libraryTopBarItems: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            AetherBrandIcon { navigationPath = NavigationPath() }
        }
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
            AetherSearchField(text: $searchQuery, prompt: "Search your library", focus: $searchFocused)
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

    @ViewBuilder
    private var content: some View {
        if isSearching {
            // Unified search across every connected source (same as Home / Search).
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
                downloads: downloads,
                hasCollections: hasCollections
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
                browseSection
                if hasAnyDownloads {
                    downloadedRail
                }
            }
            .padding(.top, AetherDesign.Spacing.l)
            .padding(.bottom, AetherDesign.Spacing.xxl)
        }
    }

    /// Browse facets (iOS / iPadOS / visionOS) as a compact horizontal pill row
    /// (#383, Infuse-style) instead of full-width disclosure rows + a "Browse"
    /// header. Genres / Years filter the local catalog; Collections / Actors /
    /// Directors query the servers and only appear when a connected source
    /// supports them (#273). Each pill navigates the same `LibraryBrowseRoute` as
    /// the old row. tvOS surfaces the same facets in its category list instead.
    @ViewBuilder
    private var browseSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AetherDesign.Spacing.s) {
                browsePill("Genres", route: .genres)
                browsePill("Years", route: .years)
                if hasCollections {
                    browsePill("Collections", route: .collections)
                }
                if connectedSources.contains(where: { $0.supportsPeople }) {
                    browsePill("Actors", route: .actors)
                    browsePill("Directors", route: .directors)
                }
            }
            .padding(.horizontal, AetherDesign.Spacing.l)
            .padding(.vertical, AetherDesign.Spacing.xxs)
        }
    }

    private func browsePill(_ title: LocalizedStringKey, route: LibraryBrowseRoute) -> some View {
        NavigationLink(value: route) {
            Text(title)
                .font(AetherDesign.Typography.metadata)
                .padding(.horizontal, AetherDesign.Spacing.m)
                .padding(.vertical, AetherDesign.Spacing.xs)
                .background(AetherDesign.Palette.surfaceElevated, in: Capsule())
                .foregroundStyle(AetherDesign.Palette.textPrimary)
        }
        .buttonStyle(.plain)
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
                // Browse facets across the whole library (#266, #273). Genres /
                // Years filter the local catalog; Collections / Actors /
                // Directors query the servers, so they only appear when a
                // connected source supports them.
                NavigationLink(value: LibraryBrowseRoute.genres) {
                    LibraryBrowseRow(title: "Genres")
                }
                .buttonStyle(.plain)
                NavigationLink(value: LibraryBrowseRoute.years) {
                    LibraryBrowseRow(title: "Years")
                }
                .buttonStyle(.plain)
                if hasCollections {
                    NavigationLink(value: LibraryBrowseRoute.collections) {
                        LibraryBrowseRow(title: "Collections")
                    }
                    .buttonStyle(.plain)
                }
                if connectedSources.contains(where: { $0.supportsPeople }) {
                    NavigationLink(value: LibraryBrowseRoute.actors) {
                        LibraryBrowseRow(title: "Actors")
                    }
                    .buttonStyle(.plain)
                    NavigationLink(value: LibraryBrowseRoute.directors) {
                        LibraryBrowseRow(title: "Directors")
                    }
                    .buttonStyle(.plain)
                }
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
            AetherCard.poster(title: item.displayTitle, posterURL: item.posterURL, isWatched: item.isFullyWatched, netflixLogoURL: availability?.netflixLogoURL(for: item))
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
                            AetherCard.poster(title: item.title, posterURL: item.posterURL, isWatched: item.isFullyWatched, rating: item.communityRating, netflixLogoURL: availability?.netflixLogoURL(for: item))
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

    /// Decide whether to show the Collections browse entry by checking for
    /// *actual* collections (not just the `supportsCollections` capability), so a
    /// Plex-only library with no collections doesn't surface a dead row (#298/#311).
    private func refreshCollectionsAvailability() async {
        let sources = connectedSources.filter { $0.supportsCollections }
        guard !sources.isEmpty else { hasCollections = false; return }
        var any = false
        await withTaskGroup(of: Bool.self) { group in
            for source in sources {
                group.addTask { !(await source.collections()).isEmpty }
            }
            for await nonEmpty in group where nonEmpty { any = true }
        }
        hasCollections = any
    }

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
