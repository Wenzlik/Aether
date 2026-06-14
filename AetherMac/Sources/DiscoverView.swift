import SwiftUI
import AetherCore

/// Discover — horizontal rails across all connected sources, mirroring the
/// mobile app's Discover tab: Recently Added, Recently Released, Top Rated,
/// plus full Movies / TV Shows rails. Each poster is a `MacPoster` wrapped in a
/// `NavigationLink` to the base `MediaItem` (the shared Detail destination).
struct DiscoverView: View {
    let session: MacSession

    @State private var rails: UnifiedRails = .empty
    @State private var isLoading = false

    var body: some View {
        ScrollView {
            if isLoading && rails.isEmpty {
                ProgressView("Loading…").padding(40)
            } else if rails.isEmpty {
                ContentUnavailableView(
                    "Nothing to discover yet",
                    systemImage: "sparkles",
                    description: Text("Connect Plex or Jellyfin to browse your library here.")
                )
                .padding(40)
            } else {
                LazyVStack(alignment: .leading, spacing: 32) {
                    rail("Recently Added", filtered(rails.recentlyAdded))
                    rail("Recently Released", filtered(rails.recentlyReleased))
                    rail("Top Rated", filtered(topRated))
                    rail("Movies", filtered(rails.movies))
                    rail("TV Shows", filtered(rails.shows))
                    ForEach(genreRails, id: \.name) { genre in
                        rail(genre.name, genre.items)
                    }
                }
                .padding(.vertical, 24)
            }
        }
        .navigationTitle("Discover")
        .task(id: session.connectedSources.count) { await load() }
    }

    /// Drop fully-watched titles when the user hides them on discovery surfaces
    /// (#280 / mobile parity) — Discover shows what's still ahead. The Library
    /// grid stays the complete catalog and is never filtered.
    private func filtered(_ items: [UnifiedMediaItem]) -> [UnifiedMediaItem] {
        guard session.playbackPrefs.hideWatchedInDiscovery else { return items }
        return items.filter { !$0.isFullyWatched }
    }

    /// Highest-rated titles across movies + shows (mobile's "Top Rated" rail).
    private var topRated: [UnifiedMediaItem] {
        (rails.movies + rails.shows)
            .filter { ($0.communityRating ?? 0) > 0 }
            .sorted { ($0.communityRating ?? 0) > ($1.communityRating ?? 0) }
            .prefix(20)
            .map { $0 }
    }

    /// One rail per popular genre across the catalog (mobile parity) — the genres
    /// with the most titles, each rail the (filtered) titles carrying that genre.
    private var genreRails: [(name: String, items: [UnifiedMediaItem])] {
        let pool = filtered(rails.movies + rails.shows)
        var counts: [String: Int] = [:]
        for item in pool { for g in item.genres { counts[g, default: 0] += 1 } }
        let topGenres = counts
            .filter { $0.value >= 3 }                       // skip near-empty rails
            .sorted { $0.value > $1.value }
            .prefix(6)
            .map(\.key)
        return topGenres.map { genre in
            (genre, pool.filter { $0.genres.contains(genre) })
        }
    }

    @ViewBuilder
    private func rail(_ title: String, _ items: [UnifiedMediaItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.title2.bold()).padding(.horizontal, 24)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 18) {
                        ForEach(items) { item in
                            if let base = item.preferredSource?.item ?? item.sources.first?.item {
                                NavigationLink(value: base) { MacPoster(item: item) }
                                    .buttonStyle(.plain)
                            } else {
                                MacPoster(item: item)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                }
            }
        }
    }

    private func load() async {
        guard session.hasAnySource else { rails = .empty; return }
        isLoading = true
        rails = await session.homeRails()
        isLoading = false
    }
}
