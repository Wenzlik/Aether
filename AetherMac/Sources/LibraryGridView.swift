import SwiftUI
import AetherCore

/// Infuse-style poster wall of the connected sources' unified library (Movies +
/// TV), via AetherCore's `UnifiedLibrary`. Tapping a poster resolves a playable
/// URL and opens a player window.
struct LibraryGridView: View {
    let session: MacSession

    @State private var movies: [UnifiedMediaItem] = []
    @State private var shows: [UnifiedMediaItem] = []
    @State private var isLoading = false

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 20)]

    var body: some View {
        ScrollView {
            if isLoading && movies.isEmpty && shows.isEmpty {
                ProgressView("Loading library…").padding(40)
            } else {
                LazyVStack(alignment: .leading, spacing: 28) {
                    section("Movies", movies)
                    section("TV Shows", shows)
                }
                .padding(24)
            }
        }
        .navigationTitle("Library")
        .task(id: session.connectedSources.count) { await load() }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [UnifiedMediaItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.title2.bold())
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(items) { item in
                        if let base = item.preferredSource?.item ?? item.sources.first?.item {
                            NavigationLink(value: base) { poster(item) }
                                .buttonStyle(.plain)
                        } else {
                            poster(item)
                        }
                    }
                }
            }
        }
    }

    private func poster(_ item: UnifiedMediaItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            CachedAsyncImage(url: item.posterURL, aspectRatio: 2.0 / 3.0)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if item.isFullyWatched {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.white, .green)
                            .padding(6)
                    }
                }
            Text(item.title).font(.callout).lineLimit(2)
            if let year = item.year {
                Text(String(year)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func load() async {
        guard session.hasAnySource else { movies = []; shows = []; return }
        isLoading = true
        let library = session.makeLibrary()
        movies = await library.unifiedItems(kind: .movie)
        shows = await library.unifiedItems(kind: .show)
        isLoading = false
    }
}
