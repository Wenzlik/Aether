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
/// single-kind browse (kept for deep links). Sortable + genre / year / rating
/// filterable, with an offline-free macOS-exclusive **On Netflix** availability
/// filter (hidden by default; reveals Netflix-only discovery when turned on).
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
    /// Availability: when on, the grid shows **Netflix-only** titles instead of
    /// your owned library (the old "On Netflix" sections, now a filter). Hidden by
    /// default; only meaningful when Netflix availability is enabled in Settings.
    @State private var onNetflixOnly = false

    @State private var sort: LibrarySort = .titleAZ
    @State private var genre: String? = nil
    /// Multi-select release years (#351) — empty = all years.
    @State private var selectedYears: Set<Int> = []
    /// Minimum community rating (#342 parity) — `nil` = any.
    @State private var minRating: Double? = nil
    /// Client-side title search within the grid (#369) — no reload.
    @State private var query = ""

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 190), spacing: 20)]
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
        genre != nil || !selectedYears.isEmpty || minRating != nil || onNetflixOnly
    }
    private var shown: [UnifiedMediaItem] {
        var filtered = typeFiltered
        if let genre { filtered = filtered.filter { $0.genres.contains(genre) } }
        if !selectedYears.isEmpty {
            filtered = filtered.filter { $0.year.map { selectedYears.contains($0) } ?? false }
        }
        if let minRating { filtered = filtered.filter { ($0.communityRating ?? 0) >= minRating } }
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

    /// Active facets as removable tokens (Availability · Genre · Rating · Year).
    /// The Movies/Series toggle is persistent, so it's *not* a token here.
    private var activeFilterTokens: [FilterToken] {
        var tokens: [FilterToken] = []
        if onNetflixOnly {
            tokens.append(.init(id: "netflix", label: "On Netflix") { self.onNetflixOnly = false })
        }
        if let genre {
            tokens.append(.init(id: "genre", label: genre) { self.genre = nil })
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
        genre = nil; selectedYears = []; minRating = nil; onNetflixOnly = false
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

    /// Persistent Movies / Series toggle chips (all-kinds landing only).
    @ViewBuilder
    private var typeToggleChips: some View {
        if kind == nil {
            HStack(spacing: 8) {
                typeChip("Movies", isOn: showMovies) { toggleType(movies: true) }
                typeChip("Series", isOn: showShows) { toggleType(movies: false) }
                Spacer()
            }
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

    /// Empty-state copy reflecting a search query / active filter (#367/#369).
    private var emptyMessage: String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let noun = title.lowercased()
        if !q.isEmpty { return "No \(noun) match “\(q)”." }
        if onNetflixOnly { return "Nothing new on Netflix right now." }
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
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(shown) { posterLink($0) }
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
            // One Filter menu: Availability (On Netflix) + Genre + Rating + Year.
            ToolbarItem {
                Menu {
                    // macOS-exclusive: surface Netflix-only discovery (hidden by
                    // default). Only when the availability feature is enabled.
                    if netflixEnabled {
                        Toggle("On Netflix", isOn: $onNetflixOnly)
                        Divider()
                    }
                    if !genres.isEmpty {
                        Picker("Genre", selection: $genre) {
                            Text("All Genres").tag(String?.none)
                            ForEach(genres, id: \.self) { Text($0).tag(Optional($0)) }
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
}
