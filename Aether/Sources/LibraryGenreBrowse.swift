import SwiftUI
import AetherCore

/// Library browsing routes beyond the per-kind Movies / TV Shows grids — the
/// first slice of the richer Library hierarchy (#266). More facets (Years,
/// Collections, Actors, Directors) slot in here as data becomes available.
enum LibraryBrowseRoute: Hashable {
    /// The unified, fully-filterable Library grid (all kinds) — the landing's
    /// Filter button opens this with the filter sheet auto-presented, so Type +
    /// Genre + Audio + Rating + Year live in one place (#369 follow-up).
    case allTitles
    case genres
    case genre(String)
    case years
    case year(Int)
    case collections
    case collection(CollectionEntry)
    case actors
    case directors
    case person(PersonEntry)
}

/// Every genre across the whole library (movies + shows), as a list of big
/// focusable rows; selecting one opens a grid of all titles in that genre.
/// Pushed inside the Library `NavigationStack`, so the `UnifiedMediaItem`
/// destination (Detail) is already registered.
struct GenreListView: View {
    let connectedSources: [any MediaSource]

    @State private var genres: [String] = []
    @State private var isLoading = false

    private var sourcesKey: String {
        connectedSources.map { $0.id.stableKey }.sorted().joined(separator: ",")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                #if os(tvOS)
                Text("Genres")
                    .font(AetherDesign.Typography.heroTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                #endif
                if isLoading && genres.isEmpty {
                    AetherLoadingState(.inline)
                } else if genres.isEmpty {
                    AetherEmptyState(glyph: "theatermasks", title: "No genres",
                                     message: "Your library's titles don't carry genres yet.")
                } else {
                    LazyVStack(spacing: AetherDesign.Spacing.m) {
                        ForEach(genres, id: \.self) { genre in
                            NavigationLink(value: LibraryBrowseRoute.genre(genre)) {
                                LibraryBrowseRow(title: genre)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, AetherDesign.Spacing.xl)
            .padding(.vertical, AetherDesign.Spacing.l)
        }
        .aetherScreenBackground()
        #if !os(tvOS)
        .navigationTitle("Genres")
        #endif
        .task(id: sourcesKey) { await load() }
    }

    private func load() async {
        guard !connectedSources.isEmpty else { genres = []; return }
        isLoading = true
        defer { isLoading = false }
        let library = UnifiedLibrary(sources: connectedSources, downloads: nil)
        async let moviesTask = library.unifiedItems(kind: .movie)
        async let showsTask = library.unifiedItems(kind: .show)
        let all = await moviesTask + showsTask
        var set = Set<String>()
        for item in all { for genre in item.genres { set.insert(genre) } }
        genres = set.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

/// A grid of every title (movies + shows) matching a facet — a genre, a year, …
/// Reused by every Library browse facet; the caller supplies the title + filter.
struct FacetGridView: View {
    let title: String
    let connectedSources: [any MediaSource]
    let downloadStore: DownloadStore?
    let filter: (UnifiedMediaItem) -> Bool

    @Environment(WatchAvailabilityStore.self) private var availability: WatchAvailabilityStore?
    @Environment(\.posterRatingSource) private var posterRatingSource

    @State private var items: [UnifiedMediaItem] = []
    @State private var isLoading = false

    private var sourcesKey: String {
        connectedSources.map { $0.id.stableKey }.sorted().joined(separator: ",")
    }

    private var columns: [GridItem] {
        #if os(tvOS)
        [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: AetherDesign.Spacing.l)]
        #else
        [GridItem(.adaptive(minimum: 120, maximum: 180), spacing: AetherDesign.Spacing.m)]
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                #if os(tvOS)
                Text(title)
                    .font(AetherDesign.Typography.heroTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                #endif
                if isLoading && items.isEmpty {
                    AetherLoadingState(.inline)
                } else if items.isEmpty {
                    AetherEmptyState(glyph: "tray", title: "Nothing here yet",
                                     message: "No \(title) titles found across your connected sources.")
                } else {
                    LazyVGrid(columns: columns, spacing: AetherDesign.Spacing.l) {
                        ForEach(items) { item in
                            NavigationLink(value: item) {
                                AetherCard.poster(title: item.title, posterURL: item.posterURL, isWatched: item.isFullyWatched, rating: item.posterRating(source: posterRatingSource), netflixLogoURL: availability?.netflixLogoURL(for: item))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, AetherDesign.Spacing.l)
            .padding(.vertical, AetherDesign.Spacing.l)
        }
        .aetherScreenBackground()
        #if !os(tvOS)
        .navigationTitle(title)
        #endif
        .task(id: sourcesKey) { await load() }
    }

    private func load() async {
        guard !connectedSources.isEmpty else { items = []; return }
        isLoading = true
        defer { isLoading = false }
        let library = UnifiedLibrary(sources: connectedSources, downloads: downloadStore)
        async let moviesTask = library.unifiedItems(kind: .movie)
        async let showsTask = library.unifiedItems(kind: .show)
        let all = await moviesTask + showsTask
        items = all
            .filter(filter)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}

/// Every release year present in the library (newest first); selecting one opens
/// a grid of all titles from that year.
struct YearListView: View {
    let connectedSources: [any MediaSource]

    @State private var years: [Int] = []
    @State private var isLoading = false

    private var sourcesKey: String {
        connectedSources.map { $0.id.stableKey }.sorted().joined(separator: ",")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                #if os(tvOS)
                Text("Years")
                    .font(AetherDesign.Typography.heroTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                #endif
                if isLoading && years.isEmpty {
                    AetherLoadingState(.inline)
                } else if years.isEmpty {
                    AetherEmptyState(glyph: "calendar", title: "No years",
                                     message: "Your library's titles don't carry release years yet.")
                } else {
                    LazyVStack(spacing: AetherDesign.Spacing.m) {
                        ForEach(years, id: \.self) { year in
                            NavigationLink(value: LibraryBrowseRoute.year(year)) {
                                LibraryBrowseRow(title: String(year))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, AetherDesign.Spacing.xl)
            .padding(.vertical, AetherDesign.Spacing.l)
        }
        .aetherScreenBackground()
        #if !os(tvOS)
        .navigationTitle("Years")
        #endif
        .task(id: sourcesKey) { await load() }
    }

    private func load() async {
        guard !connectedSources.isEmpty else { years = []; return }
        isLoading = true
        defer { isLoading = false }
        let library = UnifiedLibrary(sources: connectedSources, downloads: nil)
        async let moviesTask = library.unifiedItems(kind: .movie)
        async let showsTask = library.unifiedItems(kind: .show)
        let all = await moviesTask + showsTask
        years = Set(all.compactMap(\.year)).sorted(by: >)
    }
}

/// A big focusable browse row — title (+ optional trailing detail) + chevron —
/// matching the Library category rows. Used for genres, years, collections and
/// people facets.
struct LibraryBrowseRow: View {
    let title: String
    var detail: String? = nil
    /// Person rows (#297): a leading circular headshot, or a calm glyph
    /// placeholder when the source has no photo.
    var photoURL: URL? = nil
    var showsHeadshot: Bool = false

    var body: some View {
        HStack(spacing: AetherDesign.Spacing.m) {
            if showsHeadshot { headshot }
            Text(title)
                .font(AetherDesign.Typography.sectionTitle)
                .foregroundStyle(AetherDesign.Palette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: AetherDesign.Spacing.m)
            if let detail {
                Text(detail)
                    .font(AetherDesign.Typography.metadata)
                    .foregroundStyle(AetherDesign.Palette.textSecondary)
            }
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

    /// Circular headshot via the cached artwork pipeline, or a person glyph when
    /// the source has no photo. Kept small so person rows stay list-friendly.
    @ViewBuilder
    private var headshot: some View {
        Group {
            if let photoURL {
                CachedAsyncImage(url: photoURL, aspectRatio: 1, maxPixel: ArtworkTier.thumbnail.maxPixel)
            } else {
                ZStack {
                    AetherDesign.Palette.surfaceElevated
                    Image(systemName: "person.fill")
                        .font(.title3)
                        .foregroundStyle(AetherDesign.Palette.textTertiary)
                }
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(Circle())
    }
}
