import SwiftUI
import AetherCore

/// Navigation route for a kind-specific browse. The Library landing itself is
/// now one combined grid; this stays for any kind-scoped deep link.
enum LibraryRoute: Hashable {
    case movies, shows
    var kind: MediaItem.Kind { self == .movies ? .movie : .show }
    var title: String { self == .movies ? "Movies" : "TV Shows" }
}

/// The Library landing — one combined, filterable grid of everything (Movies +
/// TV Shows together), with a persistent Movies/Series toggle. Thin wrapper over
/// `LibraryBrowseView` in all-kinds mode.
struct LibraryGridView: View {
    let session: MacSession
    var body: some View { LibraryBrowseView(session: session, kind: nil) }
}

/// A poster that navigates to its base item's detail (shared by the library +
/// browse grids).
@MainActor @ViewBuilder
func posterLink(_ item: UnifiedMediaItem) -> some View {
    if let base = item.preferredSource?.item ?? item.sources.first?.item {
        NavigationLink(value: base) { MacPoster(item: item) }
            .buttonStyle(.plain)
    } else {
        MacPoster(item: item)
    }
}

/// The unified Library grid. `kind == nil` is the **landing**: one combined grid
/// of Movies + TV Shows with a persistent type toggle. A non-nil `kind` is a
/// single-kind browse (kept for deep links). Sortable + genre / audio / year /
/// rating filterable, with an offline-free macOS-exclusive **On Netflix**
/// availability filter (hidden by default; reveals Netflix-only discovery when
/// turned on).
struct LibraryBrowseView: View {
    let session: MacSession
    /// `nil` = all kinds (the Library landing). Else a single-kind browse.
    var kind: MediaItem.Kind? = nil

    /// Owned catalog. All-kinds mode loads Movies + TV Shows into one list and
    /// remembers which ids are shows (`showIDs`) so the toggle can split them.
    @State private var items: [UnifiedMediaItem] = []
    @State private var showIDs: Set<String> = []
    /// Netflix-only discovery titles, loaded lazily when the On-Netflix filter is
    /// on (macOS-exclusive). Owned titles are excluded by TMDb id.
    @State private var netflixItems: [UnifiedMediaItem] = []
    @State private var isLoading = false

    /// Persistent type toggles (all-kinds mode): independent, **both on = show
    /// everything**; turning the last one off snaps both back on. They depress
    /// rather than vanish — distinct from the removable facet filters.
    @State private var showMovies = true
    @State private var showShows = true
    /// Persistent "show watched" toggle — on by default; turning it off hides
    /// fully-watched titles (iOS/iPadOS parity, #445).
    @State private var showWatched = true
    /// Availability: when on, the grid shows **Netflix-only** titles instead of
    /// your owned library (the old "On Netflix" sections, now a filter). Hidden by
    /// default; only meaningful when Netflix availability is enabled in Settings.
    @State private var onNetflixOnly = false

    @State private var sort: LibrarySort = .titleAZ
    /// Multi-select genres (#445 parity with iOS) — empty = all genres.
    @State private var selectedGenres: Set<String> = []
    /// Multi-select release years (#351) — empty = all years.
    @State private var selectedYears: Set<Int> = []
    /// Minimum community rating (#342 parity) — `nil` = any.
    @State private var minRating: Double? = nil
    /// Client-side title search within the grid (#369) — no reload.
    @State private var query = ""

    // MARK: Audio language (#295/#445 parity)
    /// Selected audio language code — `nil` = All. Applied client-side from
    /// the lazily-loaded `audioMembership` set.
    @State private var selectedAudioLanguage: String?
    @State private var audioLanguageOptions: [AudioLanguageOption] = []
    /// code → set of item ids with that language; loaded lazily on first pick.
    @State private var audioMembership: [String: Set<String>] = [:]
    @State private var loadingLanguage: String?

    private let columns = [GridItem(.adaptive(minimum: 162, maximum: 220), spacing: 24)]
    private let ratingBuckets: [Double] = [9, 8, 7, 6]

    private var title: String {
        guard let kind else { return "Library" }
        return kind == .movie ? "Movies" : "TV Shows"
    }

    private var netflixEnabled: Bool {
        session.streamingPreferences.netflixAvailabilityEnabled
    }

    /// Re-fetch Netflix-only discovery when the filter flips on or the prefs /
    /// catalog change (parity with the old `netflixKey`).
    private var netflixKey: String {
        let p = session.streamingPreferences
        return "\(onNetflixOnly)-\(p.netflixAvailabilityEnabled)-\(p.region ?? "auto")-\(session.libraryToken)"
    }

    // MARK: - Derived

    /// The source set currently being browsed: Netflix-only when that filter is
    /// on, else the owned catalog.
    private var sourceItems: [UnifiedMediaItem] {
        onNetflixOnly ? netflixItems : items
    }

    /// `sourceItems` narrowed by the persistent Movies/Series toggle (all-kinds
    /// only): one selected restricts by the remembered show ids; both on / both
    /// off shows everything.
    private var typeFiltered: [UnifiedMediaItem] {
        guard kind == nil, showMovies != showShows else { return sourceItems }
        return showMovies
            ? sourceItems.filter { !showIDs.contains($0.id) }
            : sourceItems.filter { showIDs.contains($0.id) }
    }

    private var genres: [String] {
        Array(Set(sourceItems.flatMap(\.genres))).sorted()
    }
    private var years: [Int] {
        Array(Set(sourceItems.compactMap(\.year))).sorted(by: >)
    }
    private var hasActiveFilter: Bool {
        !selectedGenres.isEmpty || selectedAudioLanguage != nil || !selectedYears.isEmpty
            || minRating != nil || onNetflixOnly
    }
    private var shown: [UnifiedMediaItem] {
        var filtered = typeFiltered
        if !selectedGenres.isEmpty {
            filtered = filtered.filter { item in item.genres.contains { selectedGenres.contains($0) } }
        }
        if let language = selectedAudioLanguage, let matching = audioMembership[language] {
            filtered = filtered.filter { matching.contains($0.id) }
        }
        if !selectedYears.isEmpty {
            filtered = filtered.filter { $0.year.map { selectedYears.contains($0) } ?? false }
        }
        if let minRating { filtered = filtered.filter { ($0.communityRating ?? 0) >= minRating } }
        if !showWatched { filtered = filtered.filter { !$0.isFullyWatched } }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { filtered = filtered.filter { $0.title.localizedStandardContains(q) } }
        return sort.sorted(filtered)
    }

    /// Flip one type toggle; never allow an empty selection (turning the last one
    /// off snaps both back on, i.e. "show everything").
    private func toggleType(movies: Bool) {
        if movies { showMovies.toggle() } else { showShows.toggle() }
        if !showMovies && !showShows { showMovies = true; showShows = true }
    }

    // MARK: - Active-filter summary (#367)

    private struct FilterToken: Identifiable {
        let id: String
        let label: String
        let clear: () -> Void
    }

    /// Active facets as removable tokens (Availability · Genre · Audio · Rating ·
    /// Year). The Movies/Series/Watched toggles are persistent, so they're not
    /// tokens here.
    private var activeFilterTokens: [FilterToken] {
        var tokens: [FilterToken] = []
        if onNetflixOnly {
            tokens.append(.init(id: "netflix", label: "On Netflix") { self.onNetflixOnly = false })
        }
        for genre in selectedGenres.sorted() {
            tokens.append(.init(id: "genre-\(genre)", label: genre) { self.selectedGenres.remove(genre) })
        }
        if let selectedAudioLanguage {
            let name = audioLanguageOptions.first { $0.code == selectedAudioLanguage }?.displayName
                ?? selectedAudioLanguage
            tokens.append(.init(id: "audio", label: name) { self.selectedAudioLanguage = nil })
        }
        if let minRating {
            tokens.append(.init(id: "rating", label: "\(Int(minRating))+") { self.minRating = nil })
        }
        for year in selectedYears.sorted(by: >) {
            tokens.append(.init(id: "year-\(year)", label: String(year)) { self.selectedYears.remove(year) })
        }
        return tokens
    }

    private func clearFilters() {
        selectedGenres = []
        selectedAudioLanguage = nil
        selectedYears = []
        minRating = nil
        onNetflixOnly = false
    }

    /// Removable-chip row above the grid + Clear all (#367 parity).
    private var activeFiltersRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(activeFilterTokens) { token in
                    Button(action: token.clear) {
                        HStack(spacing: 4) {
                            Text(LocalizedStringKey(token.label))
                            Image(systemName: "xmark").font(.caption2.weight(.semibold))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(AetherMacTheme.accent, in: Capsule())
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .help("Remove \(token.label) filter")
                }
                Button("Clear all", action: clearFilters)
                    .buttonStyle(.link)
            }
            .font(.callout)
        }
    }

    /// Persistent Movies / Series / Watched toggle chips. Movies + Series only
    /// appear in all-kinds mode; Watched is always present (#445 parity with iOS).
    @ViewBuilder
    private var typeToggleChips: some View {
        HStack(spacing: 8) {
            if kind == nil {
                typeChip("Movies", isOn: showMovies) { toggleType(movies: true) }
                typeChip("Series", isOn: showShows) { toggleType(movies: false) }
            }
            typeChip("Watched", isOn: showWatched) { showWatched.toggle() }
            Spacer()
        }
    }

    private func typeChip(_ label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(LocalizedStringKey(label))
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(isOn ? AnyShapeStyle(AetherMacTheme.accent) : AnyShapeStyle(.quaternary), in: Capsule())
                .foregroundStyle(isOn ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func libraryContextMenu(_ item: UnifiedMediaItem) -> some View {
        if let base = item.preferredSource?.item ?? item.sources.first?.item {
            Button { Task { await session.play(base) } } label: {
                Label("Play", systemImage: "play.fill")
            }
            Divider()
            Button {
                Task { await session.markWatched(base, watched: !item.isFullyWatched) }
            } label: {
                Label(
                    item.isFullyWatched ? "Mark as Unwatched" : "Mark as Watched",
                    systemImage: item.isFullyWatched ? "circle" : "checkmark.circle"
                )
            }
        }
    }

    /// Empty-state copy reflecting a search query / active filter / watched state.
    private var emptyMessage: String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let noun = title.lowercased()
        if !q.isEmpty { return "No \(noun) match \"\(q)\"." }
        if onNetflixOnly { return "Nothing new on Netflix right now." }
        if !showWatched { return "All \(noun) have been watched." }
        if hasActiveFilter { return "No \(noun) match the current filters." }
        return "No \(noun) found across your connected sources."
    }

    var body: some View {
        ScrollView {
            if isLoading && sourceItems.isEmpty {
                AetherLoadingState(.rails(count: 2)).padding(.vertical, 24)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    typeToggleChips
                    if hasActiveFilter { activeFiltersRow }
                    if shown.isEmpty {
                        AetherEmptyState(glyph: "tray", title: "Nothing here", message: emptyMessage)
                            .frame(maxWidth: .infinity).padding(.top, 24)
                    } else {
                        LazyVGrid(columns: columns, spacing: 24) {
                            ForEach(shown) { item in
                                posterLink(item)
                                    .contextMenu { libraryContextMenu(item) }
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
        .cinematicBackground()
        .navigationTitle(LocalizedStringKey(title))
        .searchable(text: $query, prompt: Text("Search your library"))
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(LibrarySort.allCases, id: \.self) { s in
                            Label(s.displayName, systemImage: s.systemImage).tag(s)
                        }
                    }
                    .pickerStyle(.inline)
                } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
            }
            // Filter menu: Availability · Genre · Audio Language · Rating · Year.
            ToolbarItem {
                Menu {
                    // macOS-exclusive: surface Netflix-only discovery (hidden by
                    // default). Only when the availability feature is enabled.
                    if netflixEnabled {
                        Toggle("On Netflix", isOn: $onNetflixOnly)
                        Divider()
                    }
                    // Genre — multi-select (#445 parity with iOS).
                    if !genres.isEmpty {
                        Menu("Genre") {
                            Button {
                                selectedGenres = []
                            } label: {
                                HStack {
                                    Text("All Genres")
                                    if selectedGenres.isEmpty { Image(systemName: "checkmark") }
                                }
                            }
                            if !selectedGenres.isEmpty { Divider() }
                            ForEach(genres, id: \.self) { g in
                                Toggle(g, isOn: Binding(
                                    get: { selectedGenres.contains(g) },
                                    set: { on in
                                        if on { selectedGenres.insert(g) } else { selectedGenres.remove(g) }
                                    }
                                ))
                            }
                        }
                    }
                    // Audio language (#295/#445) — lazily loaded, shown only when
                    // at least one language is available.
                    if !audioLanguageOptions.isEmpty {
                        Menu("Audio Language") {
                            Button {
                                selectedAudioLanguage = nil
                            } label: {
                                HStack {
                                    Text("All")
                                    if selectedAudioLanguage == nil { Image(systemName: "checkmark") }
                                }
                            }
                            Divider()
                            ForEach(audioLanguageOptions) { option in
                                Toggle(option.displayName, isOn: Binding(
                                    get: { selectedAudioLanguage == option.code },
                                    set: { on in selectAudioLanguage(on ? option.code : nil) }
                                ))
                            }
                        }
                    }
                    Picker("Minimum Rating", selection: $minRating) {
                        Text("Any Rating").tag(Double?.none)
                        ForEach(ratingBuckets, id: \.self) { Text("\(Int($0))+").tag(Optional($0)) }
                    }
                    if !years.isEmpty {
                        Menu("Year") {
                            ForEach(years, id: \.self) { y in
                                Toggle(String(y), isOn: Binding(
                                    get: { selectedYears.contains(y) },
                                    set: { on in
                                        if on { selectedYears.insert(y) } else { selectedYears.remove(y) }
                                    }
                                ))
                            }
                            if !selectedYears.isEmpty {
                                Divider()
                                Button("Clear Years") { selectedYears = [] }
                            }
                        }
                    }
                    if hasActiveFilter {
                        Divider()
                        Button("Clear Filters", action: clearFilters)
                    }
                } label: {
                    Label("Filter", systemImage: hasActiveFilter
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                }
            }
            ToolbarItem {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await load(forceRefresh: true) } } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .task(id: session.libraryToken) { await load() }
        .task(id: session.libraryToken) { await loadAudioLanguageOptions() }
        .task(id: netflixKey) { await loadNetflix() }
    }

    // MARK: - Loading

    private func load(forceRefresh: Bool = false) async {
        guard session.hasAnySource else { items = []; showIDs = []; return }
        isLoading = true
        defer { isLoading = false }
        let library = session.makeLibrary()
        let fresh: [UnifiedMediaItem]
        if let kind {
            fresh = await library.unifiedItems(kind: kind, forceRefresh: forceRefresh)
            showIDs = []
        } else {
            async let moviesTask = library.unifiedItems(kind: .movie, forceRefresh: forceRefresh)
            async let showsTask = library.unifiedItems(kind: .show, forceRefresh: forceRefresh)
            let (movies, shows) = await (moviesTask, showsTask)
            fresh = movies + shows
            showIDs = Set(shows.map(\.id))
        }
        // Don't blank existing content on a transient empty result (iOS parity).
        if !fresh.isEmpty || items.isEmpty { items = fresh }
        guard !forceRefresh else { return }
        // Stale-while-revalidate: the snapshot painted instantly above; refresh
        // quietly if it's past the freshness window.
        let stale: Bool
        if let kind {
            stale = await library.isStale(kind: kind)
        } else {
            let staleMovies = await library.isStale(kind: .movie)
            let staleShows = await library.isStale(kind: .show)
            stale = staleMovies || staleShows
        }
        if stale { await load(forceRefresh: true) }
    }

    /// Fetch Netflix-only discovery for the in-scope kinds when the On-Netflix
    /// filter is on; owned titles (by TMDb id) are excluded. Cleared when off.
    private func loadNetflix() async {
        guard onNetflixOnly, netflixEnabled else { netflixItems = []; return }
        let owned = Set(items.compactMap(\.tmdbID))
        func unowned(_ list: [UnifiedMediaItem]) -> [UnifiedMediaItem] {
            list.filter { $0.tmdbID.map { !owned.contains($0) } ?? true }
        }
        var result: [UnifiedMediaItem] = []
        if kind != .show {
            result += await session.watchAvailability.netflixOnlyDiscover(isShow: false, sort: .topRated)
        }
        if kind != .movie {
            result += await session.watchAvailability.netflixOnlyDiscover(isShow: true, sort: .topRated)
        }
        netflixItems = unowned(result)
    }

    // MARK: - Audio language (#295/#445)

    /// Load audio-language options (the menu entries) once per source set.
    /// Membership for a language loads lazily on first pick.
    private func loadAudioLanguageOptions() async {
        guard session.hasAnySource else { audioLanguageOptions = []; audioMembership = [:]; return }
        let library = session.makeLibrary()
        let options: [AudioLanguageOption]
        if let kind {
            options = await library.audioLanguageOptions(kind: kind, locale: session.appLocale)
        } else {
            async let moviesTask = library.audioLanguageOptions(kind: .movie, locale: session.appLocale)
            async let showsTask = library.audioLanguageOptions(kind: .show, locale: session.appLocale)
            let merged = await moviesTask + (await showsTask)
            var seen = Set<String>()
            options = merged.filter { seen.insert($0.code).inserted }
        }
        // Only show languages the app is localized into (same filter as iOS).
        audioLanguageOptions = options.filter { appLanguageCodes.contains($0.code) }
    }

    private var appLanguageCodes: Set<String> {
        Set(Bundle.main.localizations.map { AudioLanguage.canonical($0) })
    }

    private func selectAudioLanguage(_ code: String?) {
        selectedAudioLanguage = (selectedAudioLanguage == code) ? nil : code
        guard let language = selectedAudioLanguage, audioMembership[language] == nil else { return }
        Task { await loadMembership(for: language) }
    }

    private func loadMembership(for code: String) async {
        loadingLanguage = code
        defer { if loadingLanguage == code { loadingLanguage = nil } }
        let library = session.makeLibrary()
        let ids: Set<String>
        if let kind {
            ids = await library.audioLanguageIDs(kind: kind, language: code)
        } else {
            async let moviesTask = library.audioLanguageIDs(kind: .movie, language: code)
            async let showsTask = library.audioLanguageIDs(kind: .show, language: code)
            ids = await moviesTask.union(await showsTask)
        }
        audioMembership[code] = ids
    }
}
