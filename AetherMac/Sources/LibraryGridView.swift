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
        .cinematicBackground()
        .navigationTitle("Library")
        .task(id: session.libraryToken) { await load() }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [UnifiedMediaItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.title2.bold())
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(items) { item in
                        if let base = item.preferredSource?.item ?? item.sources.first?.item {
                            NavigationLink(value: base) { MacPoster(item: item) }
                                .buttonStyle(.plain)
                        } else {
                            MacPoster(item: item)
                        }
                    }
                }
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
