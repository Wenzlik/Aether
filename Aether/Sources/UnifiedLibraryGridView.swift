import SwiftUI
import AetherCore

/// Full unified grid of every title of one kind (Movies / TV Shows) across all
/// connected sources — the "See all" target from `LibraryBrowseView`.
///
/// Deduplicated like the rest of the unified surfaces: a title on both Plex and
/// Jellyfin appears once, and each card navigates a `UnifiedMediaItem` (Detail
/// shows its Available Sources). Pushed into the Library `NavigationStack`, so
/// the `UnifiedMediaItem` destination is already registered by
/// `mediaNavigationDestinations`.
///
/// Sorting is **client-side** over the loaded unified items (no per-source
/// server sort, since the grid spans sources). The control mirrors
/// `LibraryView`: a toolbar `Menu` on iOS / iPadOS / visionOS, an inline
/// button + sheet on tvOS (which doesn't render toolbar menus usefully).
struct UnifiedLibraryGridView: View {
    let title: String
    /// The kind this grid shows. **`nil` = all kinds** (Movies + TV Shows) — the
    /// landing's unified Filter target, which adds a Type facet to the sheet.
    let kind: MediaItem.Kind?
    let connectedSources: [any MediaSource]
    let downloadStore: DownloadStore?
    /// Present the filter sheet automatically on first appear — set when the
    /// landing's Filter button pushed us, so "Filter" is one tap, not two.
    var autoOpenFilter: Bool = false
    /// When true this grid **is** the Library tab landing (not a pushed "See
    /// all"): it shows the browse pills, and leaves search + the navigation title
    /// to the hosting `LibraryBrowseView` shell (which owns the branded header).
    var isLibraryRoot: Bool = false
    /// Completed-download source for the offline "Downloaded" filter. Read
    /// reactively, so toggling a download in/out updates the grid live; present
    /// only on the landing (the pushed "See all" grids don't pass it).
    var downloads: DownloadObserver? = nil

    /// Persistent type toggles (all-kinds mode): independent, **both on = show
    /// everything**. Unlike the removable facet filters below, these never
    /// disappear — they just depress. Turning the last one off snaps both back on
    /// (an empty type selection would show nothing useful).
    @State private var showMovies = true
    @State private var showShows = true
    /// Persistent "show watched" toggle. On by default (all titles shown); turning
    /// it off hides fully-watched titles — whole movies and fully-completed series.
    @State private var showWatched = true
    /// "Downloaded only" facet — like the other filters it's removable, but it
    /// also works **offline**: it renders the completed downloads straight from
    /// the store even when the server catalog can't be fetched.
    @State private var downloadedOnly = false
    /// Ids of the loaded **show** titles, so the Type facet can split the
    /// combined catalog without a per-item kind lookup (we load the two kinds
    /// separately and remember which were shows).
    @State private var showIDs: Set<String> = []
    @State private var didAutoOpenFilter = false

    @State private var items: [UnifiedMediaItem] = []
    @State private var isLoading = false
    /// App language (#320) — audio-language option names format in this locale,
    /// not the device's `Locale.current`.
    @Environment(\.locale) private var locale
    @Environment(WatchAvailabilityStore.self) private var availability: WatchAvailabilityStore?
    /// Optional — present on iOS/tvOS/visionOS (injected by `RootTabView`), absent
    /// in isolated previews. Its `libraryRevision` is folded into the reload key so
    /// marking a title watched/unwatched re-reads the freshly-invalidated catalog.
    @Environment(AppSession.self) private var appSession: AppSession?
    @Environment(\.posterRatingSource) private var posterRatingSource
    /// Client-side title search within the category grid (#369). Filters
    /// `filteredItems` alongside the facet filters — no reload, like #319.
    @State private var searchText = ""
    @State private var sort: LibrarySort = .titleAZ
    /// Selected genres — **multi-select**, empty = all genres (#351 parity with
    /// Year). A title matches if it carries *any* selected genre. Driven by the
    /// chip row in the filter sheet.
    @State private var selectedGenres: Set<String> = []
    /// Active audio-language filter (canonical code) — `nil` = All (#295/#319).
    /// Applied **client-side** from `audioMembership`.
    @State private var selectedAudioLanguage: String?
    @State private var audioLanguageOptions: [AudioLanguageOption] = []
    /// `code -> set of UnifiedMediaItem.id` that have that audio language, filled
    /// **lazily** the first time a language is tapped and process-cached, so the
    /// grid no longer pays an eager all-languages warm-up on every visit (#319
    /// perf). A selection whose set hasn't loaded yet shows the full catalog
    /// (never the wrong language) and narrows the moment it arrives.
    @State private var audioMembership: [String: Set<String>] = [:]
    /// The language code whose membership is being fetched right now (drives a
    /// small spinner on the chip row); `nil` when nothing's loading.
    @State private var loadingLanguage: String?
    /// Minimum community rating filter (#342) — `nil` = any. Buckets, applied
    /// client-side over `communityRating`.
    @State private var selectedMinRating: Double?
    /// Selected release years (#351) — **multi-select**, empty = all years.
    /// Applied client-side; a title matches if its year is in the set.
    @State private var selectedYears: Set<Int> = []
    /// Drives the Filter sheet that now holds Genre / Audio / Rating (#342),
    /// instead of permanent chip rows above the grid.
    @State private var isFilterSheetPresented = false
    /// Rating buckets offered in the filter (label + minimum score).
    private let ratingBuckets: [(label: String, min: Double)] = [
        ("9+", 9), ("8+", 8), ("7+", 7), ("6+", 6)
    ]
    #if os(tvOS)
    @State private var isSortSheetPresented = false
    #endif

    /// Cross-source sorts, all now backed by the unified item's metadata
    /// (title, year, add date, rating). Sorting is client-side over the loaded
    /// items since the grid spans sources.
    private let sortOptions: [LibrarySort] = [
        .titleAZ, .titleZA, .yearNewest, .yearOldest, .recentlyAdded, .ratingHighest
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                // tvOS: an in-scroll heading that scrolls away with the grid.
                // `.navigationTitle` on tvOS pins a persistent title that never
                // moves and overlaps the content (fine on iOS, where the large
                // title collapses on scroll).
                #if os(tvOS)
                // LocalizedStringKey (not verbatim) so the section title
                // ("Movies" / "TV Shows" / "Library") translates via the catalog
                // in the app's locale (#320).
                Text(LocalizedStringKey(title))
                    .font(AetherDesign.Typography.heroTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                #endif
                content
            }
            .padding(.horizontal, AetherDesign.Spacing.l)
            .padding(.vertical, AetherDesign.Spacing.l)
        }
        .aetherScreenBackground()
        // Pull-to-refresh re-fetches the catalog past the cache (the Library
        // landing no longer has the shell's rail refresh).
        #if !os(tvOS)
        .refreshable { await load(forceRefresh: true) }
        #endif
        // As the Library landing the shell (`LibraryBrowseView`) owns the branded
        // header + search, so suppress the grid's own title/search there.
        .libraryNavTitle(!isLibraryRoot, title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        // Filter + Sort live as visible buttons at the top of the grid content
        // (#383, Infuse-style) rather than hidden in the top-right toolbar — the
        // trailing nav-bar slot is reserved for Search. tvOS keeps its own sort
        // sheet (toolbar menus don't render usefully there).
        #if os(tvOS)
        .sheet(isPresented: $isSortSheetPresented) { tvOSSortSheet }
        #endif
        // visionOS presents the filter as a popover anchored to the Filter button
        // (light-dismiss on tap-outside); iOS / tvOS keep the sheet.
        #if !os(visionOS)
        .sheet(isPresented: $isFilterSheetPresented) { filterSheet }
        #endif
        // Search *within* the category (#369) — client-side title match over the
        // loaded catalog, the same no-reload model as the facet filters (#319).
        // iOS/iPadOS only; tvOS keeps its existing inline controls unchanged.
        .librarySearchable(!isLibraryRoot, text: $searchText)
        // The grid loads the *full* catalog once per source set — audio + genre
        // are both client-side filters now, so a chip tap never reloads (#319).
        .task(id: reloadKey) { await load() }
        .task(id: sourcesKey) { await loadAudioLanguageOptions() }
        // When the landing's Filter button pushed us, present the filter sheet
        // immediately so "Filter" is one tap. Guarded so it fires only once (not
        // when returning from a pushed Detail).
        .onAppear {
            if autoOpenFilter, !didAutoOpenFilter {
                didAutoOpenFilter = true
                isFilterSheetPresented = true
            }
        }
    }

    private var sourcesKey: String {
        connectedSources.map { $0.id.stableKey }.sorted().joined(separator: ",")
    }

    /// Reload key for the catalog `load()`: the source set **plus** the app's
    /// library revision, so a watched toggle (which bumps the revision and drops
    /// the stale cache entries) re-fires the load and repaints fresh badges.
    private var reloadKey: String {
        "\(sourcesKey)#\(appSession?.libraryRevision ?? 0)"
    }

    @ViewBuilder
    private var content: some View {
        // Loading only blocks for the server catalog; the Downloaded filter reads
        // local state, so it stays usable (offline) even before a catalog lands.
        if isLoading && items.isEmpty && !downloadedOnly {
            // The full Library landing — show the calm rails skeleton (title +
            // poster strip, like Home/Discover), not the thin `.inline` hint pulse
            // which renders as a lone bar on an otherwise empty screen.
            AetherLoadingState(.rails(count: 2))
                .padding(.top, AetherDesign.Spacing.l)
        } else {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                // Movies/Series toggle + Filter + Sort. Filters (genre / audio /
                // rating) live behind the Filter button instead of permanent chip
                // rows (#342); the bar sits at the top of the grid content (#383).
                #if os(tvOS)
                HStack(spacing: AetherDesign.Spacing.m) {
                    typeToggleChips
                    tvOSSortTrigger
                    tvOSFilterTrigger
                    // tvOS has no pull-to-refresh, so the grid carries its own
                    // reload control (the shell no longer does).
                    tvOSReloadTrigger
                }
                #else
                iosFilterSortBar
                #endif
                // Active-filter summary (#367): removable token per facet + Clear
                // all, so a narrowed grid reads as narrowed without reopening the
                // sheet. Shown even when the result is empty, so the user can
                // always undo a filter (and, on tvOS, never lands focus-trapped).
                if hasActiveFilter {
                    activeFiltersRow
                }
                if downloadedOnly {
                    downloadedGrid
                } else if sortedItems.isEmpty {
                    AetherEmptyState(
                        glyph: "tray",
                        title: "Nothing here",
                        message: emptyMessage
                    )
                    .padding(.top, AetherDesign.Spacing.l)
                } else {
                    LazyVGrid(columns: columns, spacing: AetherDesign.Spacing.l) {
                        ForEach(sortedItems) { item in
                            NavigationLink(value: item) {
                                AetherCard.poster(title: item.title, posterURL: item.posterURL, isWatched: item.isFullyWatched, rating: item.posterRating(source: posterRatingSource), netflixLogoURL: availability?.netflixLogoURL(for: item))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Downloaded (offline) grid

    /// Completed downloads, honoring the Movies/Series toggle + title search.
    /// Built from the local `DownloadObserver` snapshot, so it works offline
    /// (downloaded movies are `.movie`, downloaded episodes `.episode` → Series).
    private var downloadedJobs: [DownloadJob] {
        var jobs = downloads?.snapshot.completed ?? []
        if kind == nil, showMovies != showShows {
            jobs = jobs.filter { showMovies ? $0.kind == .movie : $0.kind != .movie }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            jobs = jobs.filter { $0.title.localizedStandardContains(query) }
        }
        return jobs
    }

    @ViewBuilder
    private var downloadedGrid: some View {
        if downloadedJobs.isEmpty {
            AetherEmptyState(
                glyph: "arrow.down.circle",
                title: "No downloads",
                message: "Titles you download for offline viewing show up here."
            )
            .padding(.top, AetherDesign.Spacing.l)
        } else {
            LazyVGrid(columns: columns, spacing: AetherDesign.Spacing.l) {
                ForEach(downloadedJobs) { job in
                    NavigationLink(value: downloadedItem(job)) {
                        AetherCard.poster(title: job.title, posterURL: job.displayPosterURL, isWatched: false)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// A `MediaItem` reconstructed from a completed download's captured snapshot,
    /// so the card navigates to Detail (offline playback picks the local file).
    private func downloadedItem(_ job: DownloadJob) -> MediaItem {
        MediaItem(
            id: job.mediaID,
            title: job.title,
            kind: job.kind,
            posterURL: job.displayPosterURL,
            seriesTitle: job.seriesTitle,
            seasonNumber: job.seasonNumber,
            episodeNumber: job.episodeNumber
        )
    }

    /// Empty-state copy reflects whether a search query or a filter is narrowing
    /// the result.
    private var emptyMessage: String {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            return "No \(title.lowercased()) match “\(query)”."
        }
        if hasActiveFilter {
            return "No \(title.lowercased()) match the current filters."
        }
        return "No \(title.lowercased()) found across your connected sources."
    }

    /// Items after the audio-language + genre filters, before sorting. Both are
    /// client-side over the loaded catalog, so they apply instantly (#319).
    private var filteredItems: [UnifiedMediaItem] {
        var result = items
        // Persistent type toggles (all-kinds mode): one selected (the other off)
        // restricts the combined catalog by the remembered show ids; both on /
        // both off (the latter snaps back, see `toggleType`) shows everything.
        if kind == nil, showMovies != showShows {
            result = showMovies
                ? result.filter { !showIDs.contains($0.id) }
                : result.filter { showIDs.contains($0.id) }
        }
        // Audio language (#319): filter by the lazily-loaded membership set. If
        // the tapped language hasn't loaded yet, leave the set unfiltered so we
        // never flash the *wrong* language — it narrows the moment the set lands.
        if let language = selectedAudioLanguage, let matching = audioMembership[language] {
            result = result.filter { matching.contains($0.id) }
        }
        if !selectedGenres.isEmpty {
            result = result.filter { item in item.genres.contains { selectedGenres.contains($0) } }
        }
        if let selectedMinRating {
            result = result.filter { ($0.communityRating ?? 0) >= selectedMinRating }
        }
        if !selectedYears.isEmpty {
            result = result.filter { $0.year.map { selectedYears.contains($0) } ?? false }
        }
        // Hide fully-watched titles: whole movies + series where every episode is done.
        if !showWatched {
            result = result.filter { !$0.isFullyWatched }
        }
        // Title search (#369) — client-side, case/diacritic-insensitive, applied
        // last so it narrows the already-faceted set.
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter { $0.title.localizedStandardContains(query) }
        }
        return result
    }

    /// Any filter narrowing the grid — drives the Filter button's active dot and
    /// the "Clear" affordance.
    private var hasActiveFilter: Bool {
        !selectedGenres.isEmpty || selectedAudioLanguage != nil || selectedMinRating != nil
            || !selectedYears.isEmpty || downloadedOnly
    }

    private func clearFilters() {
        selectedGenres = []
        selectedAudioLanguage = nil
        selectedMinRating = nil
        selectedYears = []
        downloadedOnly = false
        // The Movies/Series toggles are persistent, not "filters" — Clear leaves
        // them untouched.
    }

    /// Flip one type toggle; never allow an empty selection (turning the last one
    /// off snaps both back on, i.e. "show everything").
    private func toggleType(movies: Bool) {
        if movies { showMovies.toggle() } else { showShows.toggle() }
        if !showMovies && !showShows {
            showMovies = true
            showShows = true
        }
    }

    // MARK: - Active-filter summary (#367)

    /// One removable active facet: a human-readable value + the action that
    /// clears just that facet. Years expand to one token each (matching the
    /// multi-select `yearFilterRow`).
    private struct FilterToken: Identifiable {
        let id: String
        /// The displayed value (genre name, rating bucket, year, audio language)
        /// — rendered via `LocalizedStringKey` so catalog-backed values (genre /
        /// "All") translate; numbers / already-localized audio names pass through.
        let label: String
        let clear: () -> Void
    }

    /// The active facets as removable tokens, in the same order the filter sheet
    /// lists its groups (Genre · Audio · Rating · Year).
    private var activeFilterTokens: [FilterToken] {
        var tokens: [FilterToken] = []
        if downloadedOnly {
            tokens.append(.init(id: "downloaded", label: "Downloaded") { self.downloadedOnly = false })
        }
        for genre in selectedGenres.sorted() {
            tokens.append(.init(id: "genre-\(genre)", label: genre) { self.selectedGenres.remove(genre) })
        }
        if let selectedAudioLanguage {
            let name = audioLanguageOptions.first { $0.code == selectedAudioLanguage }?.displayName ?? selectedAudioLanguage
            tokens.append(.init(id: "audio", label: name) { self.selectedAudioLanguage = nil })
        }
        if let selectedMinRating {
            let label = ratingBuckets.first { $0.min == selectedMinRating }?.label ?? String(format: "%.0f+", selectedMinRating)
            tokens.append(.init(id: "rating", label: label) { self.selectedMinRating = nil })
        }
        for year in selectedYears.sorted(by: >) {
            tokens.append(.init(id: "year-\(year)", label: String(year)) { self.selectedYears.remove(year) })
        }
        return tokens
    }

    /// Horizontal row of removable chips (one per active facet) + a trailing
    /// "Clear all". Mirrors `genreFilterRow`'s scroll/HStack so it reads as part
    /// of the same filter language; the chips carry a trailing ✕ to signal
    /// removal. Focusable on tvOS.
    private var activeFiltersRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AetherDesign.Spacing.s) {
                ForEach(activeFilterTokens) { token in
                    removableChip(label: token.label, onRemove: token.clear)
                }
                Button(action: clearFilters) {
                    Text("Clear all")
                        .font(AetherDesign.Typography.metadata)
                        .foregroundStyle(AetherDesign.Palette.accent)
                        .padding(.horizontal, AetherDesign.Spacing.s)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, AetherDesign.Spacing.xxs)
        }
        #if os(tvOS)
        .focusSection()
        #endif
    }

    /// A selected-facet chip with a trailing ✕ — the removable sibling of
    /// `genreChip`, same capsule language. Tapping anywhere on it removes the
    /// facet.
    private func removableChip(label: String, onRemove: @escaping () -> Void) -> some View {
        Button(action: onRemove) {
            HStack(spacing: AetherDesign.Spacing.xxs) {
                Text(LocalizedStringKey(label))
                    .font(AetherDesign.Typography.metadata)
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
            }
            .padding(.horizontal, AetherDesign.Spacing.m)
            .padding(.vertical, AetherDesign.Spacing.xs)
            .background(AetherDesign.Palette.accent, in: Capsule())
            .foregroundStyle(Color.white)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Remove \(label) filter"))
    }

    private var sortedItems: [UnifiedMediaItem] {
        // Shared, tested ordering (#294) — same rating/rated-first behaviour
        // everywhere Library sorts client-side.
        sort.sorted(filteredItems)
    }

    /// Distinct genres across the loaded items, most common first, capped so the
    /// chip row stays usable. Empty when no item carries genres → no filter UI.
    private var availableGenres: [String] {
        var counts: [String: Int] = [:]
        for item in items {
            for genre in item.genres { counts[genre, default: 0] += 1 }
        }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(12)
            .map(\.key)
    }

    /// Distinct release years across the loaded items, newest first. Empty when
    /// nothing carries a year → no Year filter group (#351).
    private var availableYears: [Int] {
        Array(Set(items.compactMap(\.year))).sorted(by: >)
    }

    private var columns: [GridItem] {
        #if os(tvOS)
        [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: AetherDesign.Spacing.l)]
        #else
        [GridItem(.adaptive(minimum: 120, maximum: 180), spacing: AetherDesign.Spacing.m)]
        #endif
    }

    // MARK: - Filter chip container

    /// Filter-sheet chip container: on iOS / iPadOS / visionOS the chips **wrap**
    /// to multiple lines so every option is visible at once (#369 follow-up — no
    /// chips hidden off-screen to the right); tvOS keeps a horizontal focus row.
    @ViewBuilder
    private func chipContainer<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        #if os(tvOS)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AetherDesign.Spacing.s) { content() }
                .padding(.vertical, AetherDesign.Spacing.xxs)
        }
        .focusSection()
        #else
        FlowLayout(spacing: AetherDesign.Spacing.s) { content() }
            .padding(.vertical, AetherDesign.Spacing.xxs)
        #endif
    }

    // MARK: - Genre filter

    /// Capsule chips: "All" + each genre, **multi-select** (parity with Year).
    /// Tapping toggles a genre in/out; "All" clears the whole selection.
    private var genreFilterRow: some View {
        chipContainer {
            genreChip(label: "All", isSelected: selectedGenres.isEmpty) { selectedGenres = [] }
            ForEach(availableGenres, id: \.self) { genre in
                genreChip(label: genre, isSelected: selectedGenres.contains(genre)) {
                    if selectedGenres.contains(genre) {
                        selectedGenres.remove(genre)
                    } else {
                        selectedGenres.insert(genre)
                    }
                }
            }
        }
    }

    // MARK: - Audio-language filter (#295/#319)

    /// Capsule chips for audio language: "Audio" label + "All" + each language.
    /// Selecting one filters the loaded catalog client-side; the first time a
    /// language is picked its membership loads (cached after), shown by a small
    /// spinner. "All" is always instant.
    private var audioLanguageFilterRow: some View {
        chipContainer {
            if loadingLanguage != nil {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, AetherDesign.Spacing.xxs)
            }
            genreChip(label: "All", isSelected: selectedAudioLanguage == nil) {
                selectAudioLanguage(nil)
            }
            ForEach(audioLanguageOptions) { option in
                genreChip(label: option.displayName, isSelected: selectedAudioLanguage == option.code) {
                    selectAudioLanguage(option.code)
                }
            }
        }
    }

    private func genreChip(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // LocalizedStringKey (not the verbatim `Text(String)` overload) so
            // "All" and genre names translate via the catalog (#343/#320); the
            // filter still keys off the raw `selectedGenres`, not this label.
            Text(LocalizedStringKey(label))
                .font(AetherDesign.Typography.metadata)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, AetherDesign.Spacing.m)
                .padding(.vertical, AetherDesign.Spacing.xs)
                .background(
                    isSelected ? AetherDesign.Palette.accent : AetherDesign.Palette.surfaceElevated,
                    in: Capsule()
                )
                .foregroundStyle(isSelected ? Color.white : AetherDesign.Palette.textSecondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Filters (#342)

    #if !os(tvOS)
    /// The in-content Filter + Sort bar (#383, Infuse-style) at the top of the
    /// grid: a Filters button carrying the active-facet count (accent-filled when
    /// any filter is on) and a Sort menu showing the current order. Replaces the
    /// old top-right toolbar glyphs (#369) so the trailing nav-bar slot is just
    /// Search.
    private var iosFilterSortBar: some View {
        // FlowLayout (not a plain HStack): on a narrow iPhone in portrait the row
        // — Movies · Series · Filters · Sort — can't fit on one line, and an HStack
        // would compress the capsules until their labels wrapped character-by-
        // character (vertical "F/i/l/t/e/r/s"). FlowLayout instead wraps whole
        // controls onto a second line, and each `barControl` is fixed to its
        // intrinsic single-line width so a capsule never shrinks below its text.
        FlowLayout(spacing: AetherDesign.Spacing.s) {
            // Persistent Movies / Series toggles lead the bar in all-kinds mode.
            typeToggleChips
            Button { isFilterSheetPresented = true } label: {
                barControl(active: hasActiveFilter) {
                    Image(systemName: "line.3.horizontal.decrease")
                    if hasActiveFilter {
                        Text("Filters (\(activeFilterTokens.count))")
                    } else {
                        Text("Filters")
                    }
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Filter")
            // visionOS: anchor the filter here as a popover so tapping outside
            // light-dismisses it (sheets there have no tap-to-dismiss); the facets
            // apply live, so dismissing keeps the choices. iOS keeps the sheet.
            #if os(visionOS)
            .popover(isPresented: $isFilterSheetPresented, arrowEdge: .top) {
                filterContent
                    .frame(width: 420, height: 600)
            }
            #endif

            Menu {
                ForEach(sortOptions, id: \.self) { option in
                    Button { sort = option } label: {
                        Label(option.displayName, systemImage: option.systemImage)
                    }
                }
            } label: {
                barControl(active: false) {
                    Image(systemName: "arrow.up.arrow.down")
                    Text("Sort: \(sort.displayName)")
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }
            .accessibilityLabel("Sort")
            .accessibilityValue(sort.displayName)
        }
    }

    /// Shared capsule styling for the in-content bar controls — accent-filled +
    /// white when `active`, else a quiet elevated surface.
    private func barControl<Content: View>(active: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: AetherDesign.Spacing.xs) { content() }
            .font(AetherDesign.Typography.metadata.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, AetherDesign.Spacing.m)
            .padding(.vertical, AetherDesign.Spacing.xs)
            .foregroundStyle(active ? Color.white : AetherDesign.Palette.textPrimary)
            .background(
                active ? AnyShapeStyle(AetherDesign.Palette.accent) : AnyShapeStyle(AetherDesign.Palette.surfaceElevated),
                in: Capsule()
            )
            // Keep the capsule at its natural single-line width so it wraps as a
            // whole control inside the bar's FlowLayout rather than compressing.
            .fixedSize(horizontal: true, vertical: false)
    }
    #else
    /// tvOS inline Filter trigger (toolbar menus don't render on tvOS).
    private var tvOSFilterTrigger: some View {
        Button { isFilterSheetPresented = true } label: {
            HStack(spacing: AetherDesign.Spacing.s) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                Text(hasActiveFilter ? "Filters · On" : "Filters")
                Image(systemName: "chevron.right")
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
            }
            .font(AetherDesign.Typography.cardTitle)
            .padding(.vertical, AetherDesign.Spacing.m)
            .padding(.horizontal, AetherDesign.Spacing.l)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay { Capsule().stroke(AetherDesign.Palette.separator, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Filters")
    }

    /// tvOS reload — there's no pull-to-refresh on the remote, so the grid carries
    /// its own force-refresh button (the Library shell no longer fetches rails).
    private var tvOSReloadTrigger: some View {
        Button { Task { await load(forceRefresh: true) } } label: {
            HStack(spacing: AetherDesign.Spacing.s) {
                Image(systemName: "arrow.clockwise")
                Text("Reload")
            }
            .font(AetherDesign.Typography.cardTitle)
            .padding(.vertical, AetherDesign.Spacing.m)
            .padding(.horizontal, AetherDesign.Spacing.l)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay { Capsule().stroke(AetherDesign.Palette.separator, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reload")
    }
    #endif

    /// Availability filter chips: All / Downloaded only. (Type — Movies / Series
    /// — moved out of the sheet to the persistent toggle in the top bar.)
    private var downloadedFilterRow: some View {
        chipContainer {
            genreChip(label: "All", isSelected: !downloadedOnly) { downloadedOnly = false }
            genreChip(label: "Downloaded", isSelected: downloadedOnly) { downloadedOnly = true }
        }
    }

    /// The persistent type + watched-state toggles for the top bar. Movies / Series
    /// only appear in all-kinds mode; Watched is always present.
    @ViewBuilder
    private var typeToggleChips: some View {
        if kind == nil {
            genreChip(label: "Movies", isSelected: showMovies) { toggleType(movies: true) }
            genreChip(label: "Series", isSelected: showShows) { toggleType(movies: false) }
        }
        genreChip(label: "Watched", isSelected: showWatched) { showWatched.toggle() }
    }

    /// Rating filter chips: Any + score buckets (9+/8+/7+/6+) over `communityRating`.
    private var ratingFilterRow: some View {
        chipContainer {
            genreChip(label: "Any", isSelected: selectedMinRating == nil) { selectedMinRating = nil }
            ForEach(ratingBuckets, id: \.min) { bucket in
                genreChip(label: bucket.label, isSelected: selectedMinRating == bucket.min) {
                    selectedMinRating = (selectedMinRating == bucket.min) ? nil : bucket.min
                }
            }
        }
    }

    /// Year filter chips (#351): "All" + each release year, **multi-select** so
    /// the grid can span several years at once. Tapping toggles a year in/out;
    /// "All" clears the whole selection.
    private var yearFilterRow: some View {
        chipContainer {
            genreChip(label: "All", isSelected: selectedYears.isEmpty) { selectedYears = [] }
            ForEach(availableYears, id: \.self) { year in
                genreChip(label: String(year), isSelected: selectedYears.contains(year)) {
                    if selectedYears.contains(year) {
                        selectedYears.remove(year)
                    } else {
                        selectedYears.insert(year)
                    }
                }
            }
        }
    }

    /// The filter facets — Genre / Audio / Rating / Year (#342/#351), reusing the
    /// chip rows (so the audio lazy-load behaviour is unchanged), plus Clear.
    /// Shared by the sheet (iOS/tvOS) and the visionOS popover.
    private var filterContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                Text("Filter")
                    .font(AetherDesign.Typography.sectionTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                // Availability — only when the landing wired the download store.
                // Lets the user narrow to downloaded titles (works offline).
                if downloads != nil {
                    filterGroup("Availability") { downloadedFilterRow }
                }
                if !availableGenres.isEmpty {
                    filterGroup("Genre") { genreFilterRow }
                }
                if !audioLanguageOptions.isEmpty {
                    filterGroup("Audio Language") { audioLanguageFilterRow }
                }
                filterGroup("Rating") { ratingFilterRow }
                if !availableYears.isEmpty {
                    filterGroup("Year") { yearFilterRow }
                }
                if hasActiveFilter {
                    Button("Clear Filters", role: .destructive) { clearFilters() }
                        .padding(.top, AetherDesign.Spacing.s)
                }
            }
            .padding(AetherDesign.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .aetherScreenBackground()
    }

    /// Filter sheet (iOS + tvOS). visionOS instead anchors `filterContent` as a
    /// popover on the Filter button (see `iosFilterSortBar`): visionOS sheets
    /// can't be dismissed by tapping outside, and the facets apply live, so a
    /// light-dismiss popover matches the expectation that tapping away closes the
    /// panel and keeps the choices.
    private var filterSheet: some View {
        #if os(tvOS)
        return NavigationStack { filterContent }
        #else
        return filterContent
            // Open full-height so every group (Show / Genre / Audio / Rating /
            // Year) is visible without scrolling past a half-sheet fold (#369
            // follow-up). Chips wrap, so nothing hides off the right edge either.
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        #endif
    }

    @ViewBuilder
    private func filterGroup<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
            Text(title)
                .font(AetherDesign.Typography.metadata)
                .foregroundStyle(AetherDesign.Palette.textTertiary)
            content()
        }
    }

    // MARK: - Sort UI

    // iOS / iPadOS / visionOS sort lives in the in-content `iosFilterSortBar`
    // (#383); tvOS keeps an inline trigger + focusable sheet below.
    #if os(tvOS)
    /// tvOS inline sort button — toolbar menus don't render usefully on tvOS,
    /// so it opens a focusable sheet (same approach as `LibraryView`).
    private var tvOSSortTrigger: some View {
        Button {
            isSortSheetPresented = true
        } label: {
            HStack(spacing: AetherDesign.Spacing.s) {
                Image(systemName: sort.systemImage)
                Text("Sort: \(sort.displayName)")
                Image(systemName: "chevron.right")
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
            }
            .font(AetherDesign.Typography.cardTitle)
            .padding(.vertical, AetherDesign.Spacing.m)
            .padding(.horizontal, AetherDesign.Spacing.l)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay { Capsule().stroke(AetherDesign.Palette.separator, lineWidth: 1) }
            // Size to content like the Filters / Reload triggers beside it — the
            // old `Spacer()` made Sort greedily fill the whole bar width, dwarfing
            // the other controls (#441 review).
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sort")
        .accessibilityValue(sort.displayName)
    }

    private var tvOSSortSheet: some View {
        NavigationStack {
            List(sortOptions, id: \.self) { option in
                Button {
                    sort = option
                    isSortSheetPresented = false
                } label: {
                    HStack {
                        Label(option.displayName, systemImage: option.systemImage)
                        Spacer()
                        if option == sort {
                            Image(systemName: "checkmark")
                                .foregroundStyle(AetherDesign.Palette.accent)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Sort by")
        }
    }
    #endif

    // MARK: - Loading

    private func load(forceRefresh: Bool = false) async {
        guard !connectedSources.isEmpty else {
            items = []
            showIDs = []
            return
        }
        let key = sourcesKey
        isLoading = true
        defer { isLoading = false }
        let library = UnifiedLibrary(sources: connectedSources, downloads: downloadStore)
        // Always the full catalog — audio + genre are client-side filters (#319).
        let fetched: [UnifiedMediaItem]
        if let kind {
            fetched = await library.unifiedItems(kind: kind, forceRefresh: forceRefresh)
            guard key == sourcesKey else { return }
            showIDs = []
        } else {
            // All-kinds mode: load Movies + TV Shows and remember which ids are
            // shows so the Type toggle can split them client-side.
            async let moviesTask = library.unifiedItems(kind: .movie, forceRefresh: forceRefresh)
            async let showsTask = library.unifiedItems(kind: .show, forceRefresh: forceRefresh)
            let movies = await moviesTask
            let shows = await showsTask
            guard key == sourcesKey else { return }
            fetched = movies + shows
            showIDs = Set(shows.map(\.id))
        }
        items = fetched
        // Warm the artwork cache for the first screenful of the grid.
        AetherImageCache.shared.prefetch(fetched.prefix(40).map(\.posterURL))
    }

    /// Derive just the audio-language **options** (the chip row) once per source
    /// set. Membership for a language loads lazily on first tap (#295/#319).
    private func loadAudioLanguageOptions() async {
        guard !connectedSources.isEmpty else {
            audioLanguageOptions = []
            audioMembership = [:]
            return
        }
        let key = sourcesKey
        let library = UnifiedLibrary(sources: connectedSources, downloads: downloadStore)
        let options: [AudioLanguageOption]
        if let kind {
            options = await library.audioLanguageOptions(kind: kind, locale: locale)
        } else {
            async let moviesTask = library.audioLanguageOptions(kind: .movie, locale: locale)
            async let showsTask = library.audioLanguageOptions(kind: .show, locale: locale)
            let merged = await moviesTask + (await showsTask)
            var seen = Set<String>()
            options = merged.filter { seen.insert($0.code).inserted }
        }
        guard key == sourcesKey else { return }
        // Show only audio languages the app itself is localized into (the app's
        // UI languages, e.g. cs / en / uk) rather than every track language in
        // the library — keeps the filter to the handful that matter here.
        audioLanguageOptions = options.filter { appLanguageCodes.contains($0.code) }
    }

    /// Canonical codes of the app's bundled UI localizations (cs / en / uk …) —
    /// the audio filter is limited to these.
    private var appLanguageCodes: Set<String> {
        Set(Bundle.main.localizations.map { AudioLanguage.canonical($0) })
    }

    /// Toggle the audio-language chip and lazily load that language's membership
    /// the first time it's picked (cached after) — no eager all-languages
    /// warm-up on grid open (#319 perf).
    private func selectAudioLanguage(_ code: String?) {
        selectedAudioLanguage = (selectedAudioLanguage == code) ? nil : code
        guard let language = selectedAudioLanguage, audioMembership[language] == nil else { return }
        Task { await loadMembership(for: language) }
    }

    private func loadMembership(for code: String) async {
        let key = sourcesKey
        loadingLanguage = code
        defer { if loadingLanguage == code { loadingLanguage = nil } }
        let library = UnifiedLibrary(sources: connectedSources, downloads: downloadStore)
        let ids: Set<String>
        if let kind {
            ids = await library.audioLanguageIDs(kind: kind, language: code)
        } else {
            async let moviesTask = library.audioLanguageIDs(kind: .movie, language: code)
            async let showsTask = library.audioLanguageIDs(kind: .show, language: code)
            ids = await moviesTask.union(await showsTask)
        }
        guard key == sourcesKey else { return }
        audioMembership[code] = ids
    }
}

/// A line-wrapping layout for filter chips — lays children left-to-right,
/// wrapping to a new line when the next child would overflow the proposed
/// width. Used so the filter sheet shows every chip at once instead of hiding
/// them in a horizontal scroller (#369 follow-up).
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        let width = maxWidth.isFinite ? maxWidth : max(0, x - spacing)
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(
                at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Conditional chrome (Library-root vs pushed "See all")

private extension View {
    /// Apply the grid's own navigation title only when it's a standalone pushed
    /// grid; as the Library landing the shell owns the branded header. tvOS uses
    /// an in-scroll heading instead of a nav title, so it's always a no-op there.
    @ViewBuilder
    func libraryNavTitle(_ enabled: Bool, _ title: String) -> some View {
        #if os(tvOS)
        self
        #else
        if enabled {
            self.navigationTitle(LocalizedStringKey(title))
        } else {
            self
        }
        #endif
    }

    /// Apply the grid's own `.searchable` only when standalone (iOS); as the
    /// Library landing the shell provides search, so a second bar would clash.
    @ViewBuilder
    func librarySearchable(_ enabled: Bool, text: Binding<String>) -> some View {
        #if os(iOS)
        if enabled {
            self.searchable(
                text: text,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: Text("Search your library")
            )
        } else {
            self
        }
        #else
        self
        #endif
    }
}
