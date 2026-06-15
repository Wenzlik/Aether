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

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 190), spacing: 20)]
    private let previewCap = 18

    var body: some View {
        ScrollView {
            if isLoading && movies.isEmpty && shows.isEmpty {
                // Calm skeleton (parity with iOS) instead of a bare spinner.
                AetherLoadingState(.rails(count: 2)).padding(.vertical, 24)
            } else {
                LazyVStack(alignment: .leading, spacing: 28) {
                    section("Movies", movies, route: .movies)
                    section("TV Shows", shows, route: .shows)
                }
                .padding(24)
            }
        }
        .cinematicBackground()
        .navigationTitle("Library")
        .toolbar {
            // macOS has no pull-to-refresh — a toolbar Reload force-refreshes the
            // unified library across sources (parity with iOS's pull-to-refresh).
            ToolbarItem {
                Button { Task { await load(forceRefresh: true) } } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .task(id: session.libraryToken) { await load() }
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

    private func load(forceRefresh: Bool = false) async {
        guard session.hasAnySource else { movies = []; shows = []; return }
        // Only show the skeleton when we have nothing yet — a warm cache/snapshot
        // paints instantly, no full-screen loading (parity with iOS, #197).
        if movies.isEmpty && shows.isEmpty { isLoading = true }
        let library = session.makeLibrary()
        movies = await library.unifiedItems(kind: .movie, forceRefresh: forceRefresh)
        shows = await library.unifiedItems(kind: .show, forceRefresh: forceRefresh)
        isLoading = false
        guard !forceRefresh else { return }
        // Stale-while-revalidate: the snapshot was served instantly above; if it's
        // older than the freshness window, quietly refresh in the background.
        let staleMovies = await library.isStale(kind: .movie)
        let staleShows = await library.isStale(kind: .show)
        if staleMovies || staleShows {
            let freshMovies = await library.unifiedItems(kind: .movie, forceRefresh: true)
            let freshShows = await library.unifiedItems(kind: .show, forceRefresh: true)
            if !freshMovies.isEmpty { movies = freshMovies }
            if !freshShows.isEmpty { shows = freshShows }
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
        return sort.sorted(filtered)
    }

    var body: some View {
        ScrollView {
            if isLoading && items.isEmpty {
                AetherLoadingState(.rails(count: 2)).padding(.vertical, 24)
            } else {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(shown) { posterLink($0) }
                }
                .padding(24)
            }
        }
        .cinematicBackground()
        .navigationTitle(route.title)
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
                Button { Task { await load(forceRefresh: true) } } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .task(id: session.libraryToken) { await load() }
    }

    private func load(forceRefresh: Bool = false) async {
        guard session.hasAnySource else { items = []; return }
        if items.isEmpty { isLoading = true }
        let library = session.makeLibrary()
        items = await library.unifiedItems(kind: route.kind, forceRefresh: forceRefresh)
        isLoading = false
        guard !forceRefresh else { return }
        if await library.isStale(kind: route.kind) {
            let fresh = await library.unifiedItems(kind: route.kind, forceRefresh: true)
            if !fresh.isEmpty { items = fresh }
        }
    }
}
