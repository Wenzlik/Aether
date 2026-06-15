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

    /// Type facet, only meaningful in all-kinds mode (`kind == nil`).
    enum KindFilter: Hashable { case all, movies, shows }
    @State private var kindFilter: KindFilter = .all
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
    #if os(iOS)
    /// Regular (iPad) shows the Filter control's text label; compact (iPhone)
    /// falls back to icon-only (#369).
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    /// Client-side title search within the category grid (#369). Filters
    /// `filteredItems` alongside the facet filters — no reload, like #319.
    @State private var searchText = ""
    @State private var sort: LibrarySort = .titleAZ
    /// Active genre filter — `nil` = All. Driven by the chip row above the grid.
    @State private var selectedGenre: String?
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
        #if !os(tvOS)
        .navigationTitle(LocalizedStringKey(title))
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        #if !os(tvOS)
        // Filter before Sort so Filter sits on the left of the cluster —
        // consistent with the Library landing (Filter left of Search).
        .toolbar { filterToolbarItem; sortToolbarItem }
        #else
        .sheet(isPresented: $isSortSheetPresented) { tvOSSortSheet }
        #endif
        .sheet(isPresented: $isFilterSheetPresented) { filterSheet }
        // Search *within* the category (#369) — client-side title match over the
        // loaded catalog, the same no-reload model as the facet filters (#319).
        // iOS/iPadOS only; tvOS keeps its existing inline controls unchanged.
        #if os(iOS)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: Text("Search your library"))
        #endif
        // The grid loads the *full* catalog once per source set — audio + genre
        // are both client-side filters now, so a chip tap never reloads (#319).
        .task(id: sourcesKey) { await load() }
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

    @ViewBuilder
    private var content: some View {
        if isLoading && items.isEmpty {
            AetherLoadingState(.inline)
                .padding(.top, AetherDesign.Spacing.l)
        } else {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                // Filters (genre / audio / rating) now live behind the Filter
                // button (toolbar on iOS, inline trigger on tvOS) instead of
                // permanent chip rows, freeing vertical space (#342).
                #if os(tvOS)
                HStack(spacing: AetherDesign.Spacing.m) {
                    tvOSSortTrigger
                    tvOSFilterTrigger
                }
                #endif
                // Active-filter summary (#367): removable token per facet + Clear
                // all, so a narrowed grid reads as narrowed without reopening the
                // sheet. Shown even when the result is empty, so the user can
                // always undo a filter (and, on tvOS, never lands focus-trapped).
                if hasActiveFilter {
                    activeFiltersRow
                }
                if sortedItems.isEmpty {
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
                                AetherCard.poster(title: item.title, posterURL: item.posterURL, isWatched: item.isFullyWatched, rating: item.communityRating, netflixLogoURL: availability?.netflixLogoURL(for: item))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
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
        // Type facet (all-kinds mode only): split the combined catalog by the
        // remembered show ids.
        if kind == nil {
            switch kindFilter {
            case .all:    break
            case .movies: result = result.filter { !showIDs.contains($0.id) }
            case .shows:  result = result.filter { showIDs.contains($0.id) }
            }
        }
        // Audio language (#319): filter by the lazily-loaded membership set. If
        // the tapped language hasn't loaded yet, leave the set unfiltered so we
        // never flash the *wrong* language — it narrows the moment the set lands.
        if let language = selectedAudioLanguage, let matching = audioMembership[language] {
            result = result.filter { matching.contains($0.id) }
        }
        if let selectedGenre {
            result = result.filter { $0.genres.contains(selectedGenre) }
        }
        if let selectedMinRating {
            result = result.filter { ($0.communityRating ?? 0) >= selectedMinRating }
        }
        if !selectedYears.isEmpty {
            result = result.filter { $0.year.map { selectedYears.contains($0) } ?? false }
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
        selectedGenre != nil || selectedAudioLanguage != nil || selectedMinRating != nil
            || !selectedYears.isEmpty || (kind == nil && kindFilter != .all)
    }

    private func clearFilters() {
        selectedGenre = nil
        selectedAudioLanguage = nil
        selectedMinRating = nil
        selectedYears = []
        kindFilter = .all
    }

    /// Localized label for the active Type facet chip / token.
    private var kindFilterLabel: String {
        kindFilter == .movies ? "Movies" : "TV Shows"
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
        if kind == nil, kindFilter != .all {
            tokens.append(.init(id: "type", label: kindFilterLabel) { self.kindFilter = .all })
        }
        if let selectedGenre {
            tokens.append(.init(id: "genre", label: selectedGenre) { self.selectedGenre = nil })
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

    /// Capsule chips: "All" + each genre. Tapping filters the grid in place.
    private var genreFilterRow: some View {
        chipContainer {
            genreChip(label: "All", isSelected: selectedGenre == nil) { selectedGenre = nil }
            ForEach(availableGenres, id: \.self) { genre in
                genreChip(label: genre, isSelected: selectedGenre == genre) {
                    // Tapping the active genre again clears the filter.
                    selectedGenre = (selectedGenre == genre) ? nil : genre
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
            // filter still keys off the raw `selectedGenre`, not this label.
            Text(LocalizedStringKey(label))
                .font(AetherDesign.Typography.metadata)
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
    /// iOS Filter control (next to Sort + Search) — opens the filter sheet. Now
    /// **labeled** so it reads as "Filter", not a bare glyph (#369): the text
    /// shows on regular width (iPad), icon-only on compact (iPhone). A filled
    /// icon still marks active filters (ties to the #367 summary row).
    private var filterToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { isFilterSheetPresented = true } label: { filterLabel }
                .accessibilityLabel("Filter")
        }
    }

    private var filterIcon: String {
        hasActiveFilter ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
    }

    /// iPad shows "Filter" beside the glyph; iPhone (compact) stays icon-only so
    /// the bar isn't crowded next to Search + Sort (#369).
    @ViewBuilder
    private var filterLabel: some View {
        #if os(iOS)
        if horizontalSizeClass == .regular {
            Label("Filter", systemImage: filterIcon).labelStyle(.titleAndIcon)
        } else {
            Label("Filter", systemImage: filterIcon).labelStyle(.iconOnly)
        }
        #else
        Label("Filter", systemImage: filterIcon).labelStyle(.iconOnly)
        #endif
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
    #endif

    /// Type filter chips (all-kinds mode): All / Movies / TV Shows.
    private var typeFilterRow: some View {
        chipContainer {
            genreChip(label: "All", isSelected: kindFilter == .all) { kindFilter = .all }
            genreChip(label: "Movies", isSelected: kindFilter == .movies) {
                kindFilter = (kindFilter == .movies) ? .all : .movies
            }
            genreChip(label: "TV Shows", isSelected: kindFilter == .shows) {
                kindFilter = (kindFilter == .shows) ? .all : .shows
            }
        }
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

    /// Filter sheet — Genre / Audio / Rating / Year (#342/#351), reusing the chip
    /// rows (so the audio lazy-load behaviour is unchanged), plus Clear.
    private var filterSheet: some View {
        let sheetBody = ScrollView {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                Text("Filter")
                    .font(AetherDesign.Typography.sectionTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                // Type facet — only in all-kinds mode (the unified Library grid),
                // so movies/shows can be picked alongside the other facets.
                if kind == nil {
                    filterGroup("Show") { typeFilterRow }
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
        #if os(tvOS)
        return NavigationStack { sheetBody }
        #else
        return sheetBody
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

    #if !os(tvOS)
    private var sortToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                ForEach(sortOptions, id: \.self) { option in
                    Button {
                        sort = option
                    } label: {
                        Label(option.displayName, systemImage: option.systemImage)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
        }
    }
    #else
    /// tvOS inline sort button — toolbar menus don't render usefully on tvOS,
    /// so it opens a focusable sheet (same approach as `LibraryView`).
    private var tvOSSortTrigger: some View {
        Button {
            isSortSheetPresented = true
        } label: {
            HStack(spacing: AetherDesign.Spacing.s) {
                Image(systemName: sort.systemImage)
                Text("Sort: \(sort.displayName)")
                Spacer()
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

    private func load() async {
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
            fetched = await library.unifiedItems(kind: kind)
            guard key == sourcesKey else { return }
            showIDs = []
        } else {
            // All-kinds mode: load Movies + TV Shows and remember which ids are
            // shows so the Type facet can split them client-side.
            async let moviesTask = library.unifiedItems(kind: .movie)
            async let showsTask = library.unifiedItems(kind: .show)
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
