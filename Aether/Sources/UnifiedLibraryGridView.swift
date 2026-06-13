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
    let kind: MediaItem.Kind
    let connectedSources: [any MediaSource]
    let downloadStore: DownloadStore?

    @State private var items: [UnifiedMediaItem] = []
    @State private var isLoading = false
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
                Text(title)
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
        .navigationTitle(title)
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        #if !os(tvOS)
        .toolbar { sortToolbarItem }
        #else
        .sheet(isPresented: $isSortSheetPresented) { tvOSSortSheet }
        #endif
        // The grid loads the *full* catalog once per source set — audio + genre
        // are both client-side filters now, so a chip tap never reloads (#319).
        .task(id: sourcesKey) { await load() }
        .task(id: sourcesKey) { await loadAudioLanguageOptions() }
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
                #if os(tvOS)
                tvOSSortTrigger
                #endif
                if !availableGenres.isEmpty {
                    genreFilterRow
                }
                // Audio filter stays visible whenever the catalog has languages —
                // even with zero results — so a too-narrow filter can be cleared.
                if !audioLanguageOptions.isEmpty {
                    audioLanguageFilterRow
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
                                AetherCard.poster(title: item.title, posterURL: item.posterURL, isWatched: item.isFullyWatched)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    /// Empty-state copy reflects whether a filter is narrowing the result.
    private var emptyMessage: String {
        if selectedAudioLanguage != nil || selectedGenre != nil {
            return "No \(title.lowercased()) match the current filters."
        }
        return "No \(title.lowercased()) found across your connected sources."
    }

    /// Items after the audio-language + genre filters, before sorting. Both are
    /// client-side over the loaded catalog, so they apply instantly (#319).
    private var filteredItems: [UnifiedMediaItem] {
        var result = items
        // Audio language (#319): filter by the lazily-loaded membership set. If
        // the tapped language hasn't loaded yet, leave the set unfiltered so we
        // never flash the *wrong* language — it narrows the moment the set lands.
        if let language = selectedAudioLanguage, let matching = audioMembership[language] {
            result = result.filter { matching.contains($0.id) }
        }
        if let selectedGenre {
            result = result.filter { $0.genres.contains(selectedGenre) }
        }
        return result
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

    private var columns: [GridItem] {
        #if os(tvOS)
        [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: AetherDesign.Spacing.l)]
        #else
        [GridItem(.adaptive(minimum: 120, maximum: 180), spacing: AetherDesign.Spacing.m)]
        #endif
    }

    // MARK: - Genre filter

    /// Horizontal capsule chips: "All" + each genre. Tapping filters the grid in
    /// place. Mirrors the season-selector chips on Series Detail for consistency.
    private var genreFilterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AetherDesign.Spacing.s) {
                genreChip(label: "All", isSelected: selectedGenre == nil) { selectedGenre = nil }
                ForEach(availableGenres, id: \.self) { genre in
                    genreChip(label: genre, isSelected: selectedGenre == genre) {
                        // Tapping the active genre again clears the filter.
                        selectedGenre = (selectedGenre == genre) ? nil : genre
                    }
                }
            }
            .padding(.vertical, AetherDesign.Spacing.xxs)
        }
        #if os(tvOS)
        .focusSection()
        #endif
    }

    // MARK: - Audio-language filter (#295/#319)

    /// Capsule chips for audio language: "Audio" label + "All" + each language.
    /// Selecting one filters the loaded catalog client-side; the first time a
    /// language is picked its membership loads (cached after), shown by a small
    /// spinner. "All" is always instant.
    private var audioLanguageFilterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AetherDesign.Spacing.s) {
                Label("Audio", systemImage: "waveform")
                    .font(AetherDesign.Typography.metadata)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
                    .padding(.trailing, AetherDesign.Spacing.xxs)
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
            .padding(.vertical, AetherDesign.Spacing.xxs)
        }
        #if os(tvOS)
        .focusSection()
        #endif
    }

    private func genreChip(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
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
            return
        }
        let key = sourcesKey
        isLoading = true
        defer { isLoading = false }
        let library = UnifiedLibrary(sources: connectedSources, downloads: downloadStore)
        // Always the full catalog — audio + genre are client-side filters (#319).
        let fetched = await library.unifiedItems(kind: kind)
        // Drop a stale result if the source set changed while we were loading.
        guard key == sourcesKey else { return }
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
        let options = await library.audioLanguageOptions(kind: kind)
        guard key == sourcesKey else { return }
        audioLanguageOptions = options
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
        let ids = await library.audioLanguageIDs(kind: kind, language: code)
        guard key == sourcesKey else { return }
        audioMembership[code] = ids
    }
}
