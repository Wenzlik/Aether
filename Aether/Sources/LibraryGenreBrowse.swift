import SwiftUI
import AetherCore

/// Library browsing routes beyond the per-kind Movies / TV Shows grids — the
/// first slice of the richer Library hierarchy (#266). More facets (Years,
/// Collections, Actors, Directors) slot in here as data becomes available.
enum LibraryBrowseRoute: Hashable {
    case genres
    case genre(String)
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

/// A grid of every title (movies + shows) in one genre.
struct GenreGridView: View {
    let genre: String
    let connectedSources: [any MediaSource]
    let downloadStore: DownloadStore?

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
                Text(genre)
                    .font(AetherDesign.Typography.heroTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                #endif
                if isLoading && items.isEmpty {
                    AetherLoadingState(.inline)
                } else if items.isEmpty {
                    AetherEmptyState(glyph: "tray", title: "Nothing here yet",
                                     message: "No \(genre) titles found across your connected sources.")
                } else {
                    LazyVGrid(columns: columns, spacing: AetherDesign.Spacing.l) {
                        ForEach(items) { item in
                            NavigationLink(value: item) {
                                AetherCard.poster(title: item.title, posterURL: item.posterURL, isWatched: item.isFullyWatched)
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
        .navigationTitle(genre)
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
            .filter { $0.genres.contains(genre) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}

/// A big focusable browse row — title + chevron — matching the Library category
/// rows. Used for genres (and future facets).
struct LibraryBrowseRow: View {
    let title: String

    var body: some View {
        HStack(spacing: AetherDesign.Spacing.m) {
            Text(title)
                .font(AetherDesign.Typography.sectionTitle)
                .foregroundStyle(AetherDesign.Palette.textPrimary)
            Spacer(minLength: AetherDesign.Spacing.m)
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
}
