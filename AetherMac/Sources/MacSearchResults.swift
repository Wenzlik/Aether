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
    /// Netflix-only matches for the query (#360), deduped against owned results.
    @State private var netflixResults: [UnifiedMediaItem] = []
    @State private var isLoading = false

    private let columns = [GridItem(.adaptive(minimum: 162, maximum: 220), spacing: 24)]

    private var results: [UnifiedMediaItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let owned = items.filter {
            $0.title.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        // Netflix-only last, deduped against owned by unified id + TMDb id.
        let ownedTMDb = Set(owned.compactMap(\.tmdbID))
        var seen = Set(owned.map(\.id))
        let netflixOnly = netflixResults.filter {
            guard seen.insert($0.id).inserted else { return false }
            return $0.tmdbID.map { !ownedTMDb.contains($0) } ?? true
        }
        return owned + netflixOnly
    }

    var body: some View {
        Group {
            if isLoading && items.isEmpty {
                ProgressView("Searching…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 24) {
                        ForEach(results) { item in
                            if let base = item.preferredSource?.item ?? item.sources.first?.item {
                                NavigationLink(value: item) { MacPoster(item: item) }
                                    .buttonStyle(.plain)
                                    .contextMenu {
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
        .task(id: session.libraryToken) { await load() }
        .task(id: netflixSearchKey) { await loadNetflixMatches() }
    }

    /// Re-key the Netflix search on query + toggle/region changes.
    private var netflixSearchKey: String {
        let p = session.streamingPreferences
        return "\(query)-\(p.netflixAvailabilityEnabled)-\(p.showNetflixOnlyTitles)-\(p.region ?? "auto")"
    }

    private func loadNetflixMatches() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard session.watchAvailability.showsNetflixOnly, trimmed.count >= 2 else {
            netflixResults = []
            return
        }
        netflixResults = await session.watchAvailability.netflixOnlySearch(trimmed)
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
