import SwiftUI
import AetherCore

/// Search results across the connected sources' unified library. Matches titles
/// diacritic- and case-insensitively, so "pribehy" finds "Příběhy" and an app
/// in English still finds Czech titles (mobile parity, #345). Catalog loads once
/// per source set; filtering is client-side per keystroke.
struct MacSearchResults: View {
    let session: MacSession
    let query: String

    @State private var items: [UnifiedMediaItem] = []
    @State private var isLoading = false

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 20)]

    private var results: [UnifiedMediaItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return items.filter {
            $0.title.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    var body: some View {
        Group {
            if isLoading && items.isEmpty {
                ProgressView("Searching…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(results) { item in
                            if let base = item.preferredSource?.item ?? item.sources.first?.item {
                                NavigationLink(value: base) { MacPoster(item: item) }
                                    .buttonStyle(.plain)
                            } else {
                                MacPoster(item: item)
                            }
                        }
                    }
                    .padding(24)
                }
            }
        }
        .navigationTitle("Search")
        .task(id: session.connectedSources.count) { await load() }
    }

    private func load() async {
        guard session.hasAnySource else { items = []; return }
        isLoading = true
        let library = session.makeLibrary()
        async let movies = library.unifiedItems(kind: .movie)
        async let shows = library.unifiedItems(kind: .show)
        items = await movies + shows
        isLoading = false
    }
}
