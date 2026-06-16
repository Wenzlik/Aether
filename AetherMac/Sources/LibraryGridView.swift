import SwiftUI
import AetherCore

/// Navigation route for "See All" — a kind-specific full browse.
enum LibraryRoute: Hashable {
    case movies, shows
    var kind: MediaItem.Kind { self == .movies ? .movie : .show }
    var title: String { self == .movies ? "Movies" : "TV Shows" }
}

/// Library landing: Movies and TV Shows as separate, capped sections, each with
/// a **See All** that opens a sortable/filterable browse of just that kind —
/// matching the iOS Library.
struct LibraryGridView: View {
    let session: MacSession

    @State private var movies: [UnifiedMediaItem] = []
    @State private var shows: [UnifiedMediaItem] = []
    @State private var isLoading = false

    /// Netflix-only titles for the "On Netflix" sections — macOS exclusive.
    @State private var netflixMovies: [UnifiedMediaItem] = []
    @State private var netflixShows: [UnifiedMediaItem] = []

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 190), spacing: 20)]
    private let previewCap = 18

    private var netflixKey: String {
        let p = session.streamingPreferences
        return "\(p.netflixAvailabilityEnabled)-\(p.region ?? "auto")-\(session.libraryToken)"
    }

    var body: some View {
        ScrollView {
            if isLoading && movies.isEmpty && shows.isEmpty {
                AetherLoadingState(.rails(count: 2)).padding(.vertical, 24)
            } else {
                LazyVStack(alignment: .leading, spacing: 28) {
                    section("Movies", movies, route: .movies)
                    section("TV Shows", shows, route: .shows)
                    netflixSection("Movies on Netflix", netflixMovies)
                    netflixSection("Shows on Netflix", netflixShows)
                }
                .padding(24)
            }
        }
        .cinematicBackground()
        .navigationTitle("Library")
        .toolbar {
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

    /// Netflix-only section — only renders when the feature is on and items exist.
    @ViewBuilder
    private func netflixSection(_ title: String, _ items: [UnifiedMediaItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                AetherSectionHeader(title: title)
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(items.prefix(previewCap)) { item in
                        posterLink(item)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [UnifiedMediaItem], route: LibraryRoute) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                // "See All" only when the section is capped.
                AetherSectionHeader(
                    title: title,
                    accessoryTitle: items.count > previewCap ? "See All" : nil
                )
                .overlay(alignment: .trailing) {
                    if items.count > previewCap {
                        NavigationLink(value: route) { Text("See All") }
                            .buttonStyle(.link)
                    }
                }
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(items.prefix(previewCap)) { item in
                        posterLink(item)
                    }
                }
            }
        }
    }

    private func loadNetflix() async {
        guard session.streamingPreferences.netflixAvailabilityEnabled else {
            netflixMovies = []; netflixShows = []
            return
        }
        let owned = Set((movies + shows).compactMap(\.tmdbID))
        func unowned(_ items: [UnifiedMediaItem]) -> [UnifiedMediaItem] {
            Array(items.filter { $0.tmdbID.map { !owned.contains($0) } ?? true }.prefix(previewCap))
        }
        async let fetchMovies = session.watchAvailability.netflixOnlyDiscover(isShow: false, sort: .topRated)
        async let fetchShows = session.watchAvailability.netflixOnlyDiscover(isShow: true, sort: .topRated)
        let (m, s) = await (fetchMovies, fetchShows)
        netflixMovies = unowned(m)
        netflixShows = unowned(s)
    }

    private func load(forceRefresh: Bool = false) async {
        guard session.hasAnySource else { movies = []; shows = []; return }
        // Always mark loading (iOS parity): the skeleton still only shows over an
        // empty grid (warm cache/snapshot paints instantly), but on a reload over
        // existing content the toolbar spinner gives feedback.
        isLoading = true
        defer { isLoading = false }
        let library = session.makeLibrary()
        let freshMovies = await library.unifiedItems(kind: .movie, forceRefresh: forceRefresh)
        let freshShows = await library.unifiedItems(kind: .show, forceRefresh: forceRefresh)
        // Don't blank existing content on a transient empty result (iOS parity).
        if !freshMovies.isEmpty || movies.isEmpty { movies = freshMovies }
        if !freshShows.isEmpty || shows.isEmpty { shows = freshShows }
        guard !forceRefresh else { return }
        // Stale-while-revalidate: the snapshot was served instantly above; if it's
        // older than the freshness window, quietly refresh in the background.
        let staleMovies = await library.isStale(kind: .movie)
        let staleShows = await library.isStale(kind: .show)
        if staleMovies || staleShows {
            let m = await library.unifiedItems(kind: .movie, forceRefresh: true)
            let s = await library.unifiedItems(kind: .show, forceRefresh: true)
            if !m.isEmpty { movies = m }
            if !s.isEmpty { shows = s }
        }
    }
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

/// Full, sortable + genre-filterable grid of one kind (Movies or TV Shows),
/// reached via "See All". Mirrors the iOS Library browse.
struct LibraryBrowseView: View {
    let session: MacSession
    let route: LibraryRoute

    @State private var items: [UnifiedMediaItem] = []
    @State private var sort: LibrarySort = .titleAZ
    @State private var genre: String? = nil
    /// Multi-select release years (#351) — empty = all years.
    @State private var selectedYears: Set<Int> = []
    /// Minimum community rating (#342 parity) — `nil` = any.
    @State private var minRating: Double? = nil
    /// Client-side title search within the category grid (#369) — no reload,
    /// like the facet filters.
    @State private var query = ""
    @State private var isLoading = false

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 190), spacing: 20)]
    private let ratingBuckets: [Double] = [9, 8, 7, 6]

    private var genres: [String] {
        Array(Set(items.flatMap(\.genres))).sorted()
    }
    /// Distinct release years, newest first (#351).
    private var years: [Int] {
        Array(Set(items.compactMap(\.year))).sorted(by: >)
    }
    private var hasActiveFilter: Bool {
        genre != nil || !selectedYears.isEmpty || minRating != nil
    }
    private var shown: [UnifiedMediaItem] {
        var filtered = items
        if let genre { filtered = filtered.filter { $0.genres.contains(genre) } }
        if !selectedYears.isEmpty {
            filtered = filtered.filter { $0.year.map { selectedYears.contains($0) } ?? false }
        }
        if let minRating { filtered = filtered.filter { ($0.communityRating ?? 0) >= minRating } }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { filtered = filtered.filter { $0.title.localizedStandardContains(q) } }
        return sort.sorted(filtered)
    }

    // MARK: - Active-filter summary (#367)

    /// One removable active facet: a value to show + the action clearing just it.
    private struct FilterToken: Identifiable {
        let id: String
        let label: String
        let clear: () -> Void
    }

    /// Active facets as removable tokens, in the filter menu's order (Genre ·
    /// Rating · Year). Years expand to one token each (multi-select).
    private var activeFilterTokens: [FilterToken] {
        var tokens: [FilterToken] = []
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

    /// Removable-chip row above the grid + Clear all (#367 macOS parity), so a
    /// narrowed grid reads as narrowed without opening the Filter menu.
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
                Button("Clear all") { genre = nil; selectedYears = []; minRating = nil }
                    .buttonStyle(.link)
            }
            .font(.callout)
        }
    }

    /// Empty-state copy reflecting a search query / active filter (#367/#369).
    private var emptyMessage: String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { return "No \(route.title.lowercased()) match “\(q)”." }
        if hasActiveFilter { return "No \(route.title.lowercased()) match the current filters." }
        return "No \(route.title.lowercased()) found across your connected sources."
    }

    var body: some View {
        ScrollView {
            if isLoading && items.isEmpty {
                AetherLoadingState(.rails(count: 2)).padding(.vertical, 24)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    // Active-filter summary (#367 macOS parity).
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
        .navigationTitle(route.title)
        // Search within the category (#369) — client-side title match, no reload.
        .searchable(text: $query, prompt: Text("Search your library"))
        .toolbar {
            ToolbarItem {
                Menu {
                    // Inline so the options show on the first click — a plain
                    // Picker nests them behind a "Sort >" submenu (extra click).
                    Picker("Sort", selection: $sort) {
                        ForEach(LibrarySort.allCases, id: \.self) { s in
                            Label(s.displayName, systemImage: s.systemImage).tag(s)
                        }
                    }
                    .pickerStyle(.inline)
                } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
            }
            // One Filter menu: Genre + Rating + Year (multi-select) (#342/#351).
            ToolbarItem {
                Menu {
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
                        Button("Clear Filters") { genre = nil; selectedYears = []; minRating = nil }
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
    }

    private func load(forceRefresh: Bool = false) async {
        guard session.hasAnySource else { items = []; return }
        isLoading = true
        defer { isLoading = false }
        let library = session.makeLibrary()
        let fresh = await library.unifiedItems(kind: route.kind, forceRefresh: forceRefresh)
        // Don't blank existing content on a transient empty result (iOS parity).
        if !fresh.isEmpty || items.isEmpty { items = fresh }
        guard !forceRefresh else { return }
        if await library.isStale(kind: route.kind) {
            let revalidated = await library.unifiedItems(kind: route.kind, forceRefresh: true)
            if !revalidated.isEmpty { items = revalidated }
        }
    }
}
