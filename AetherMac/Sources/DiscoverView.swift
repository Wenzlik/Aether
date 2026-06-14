import SwiftUI
import AetherCore

/// Horizontal rails across all connected sources. Two modes share the same
/// loaded `UnifiedRails`:
/// - `.home` — Continue Watching, Recently Added/Released, Top Rated.
/// - `.discover` — browse by genre, plus the full Movies / TV Shows rails.
/// Each poster is a `MacPoster` wrapped in a `NavigationLink` to the base
/// `MediaItem` (the shared Detail destination).
struct DiscoverView: View {
    enum Mode { case home, discover }
    let session: MacSession
    var mode: Mode = .discover

    @State private var rails: UnifiedRails = .empty
    @State private var isLoading = false

    var body: some View {
        ScrollView {
            if isLoading && rails.isEmpty {
                ProgressView("Loading…").padding(40)
            } else if rails.isEmpty {
                ContentUnavailableView(
                    "Nothing here yet",
                    systemImage: "sparkles",
                    description: Text("Connect Plex or Jellyfin in Settings to browse your library.")
                )
                .padding(40)
            } else {
                LazyVStack(alignment: .leading, spacing: 32) {
                    switch mode {
                    case .home:
                        continueWatchingRail
                        rail("Recently Added", filtered(rails.recentlyAdded))
                        rail("Recently Released", filtered(rails.recentlyReleased))
                        rail("Top Rated", filtered(topRated))
                    case .discover:
                        ForEach(genreRails, id: \.name) { genre in
                            rail(genre.name, genre.items)
                        }
                        rail("Movies", filtered(rails.movies))
                        rail("TV Shows", filtered(rails.shows))
                    }
                }
                .padding(.vertical, 24)
            }
        }
        .navigationTitle(mode == .home ? "Home" : "Discover")
        // Reload when sources change AND after a player records a resume point,
        // so Continue Watching reflects what was just played.
        .task(id: "\(session.connectedSources.count)-\(session.resumeRevision)") { await load() }
    }

    /// In-progress titles (movies + episodes) as landscape cards with a progress
    /// bar — the "pick up where you left off" rail, like the mobile Home.
    @ViewBuilder
    private var continueWatchingRail: some View {
        if !rails.continueWatching.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Continue Watching").font(.title2.bold()).padding(.horizontal, 24)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 18) {
                        ForEach(rails.continueWatching) { entry in
                            NavigationLink(value: entry.item) {
                                ContinueWatchingCard(entry: entry)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 24)
                }
            }
        }
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

/// A landscape Continue Watching card: backdrop still, a resume progress bar,
/// and a title line that names the episode (`Show · S1E2 · …`) when relevant.
private struct ContinueWatchingCard: View {
    let entry: HomeFeed.ContinueWatchingEntry
    private let width: CGFloat = 240

    private var progress: Double {
        guard let runtime = entry.item.runtime else { return 0 }
        let total = DetailFormatting.seconds(runtime)
        guard total > 0 else { return 0 }
        return min(1, max(0, DetailFormatting.seconds(entry.resume.position) / total))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CachedAsyncImage(url: entry.item.backdropURL ?? entry.item.posterURL, aspectRatio: 16.0 / 9.0)
                .frame(width: width)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .bottom) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.white.opacity(0.25))
                            Rectangle().fill(.tint).frame(width: geo.size.width * progress)
                        }
                        .frame(height: 4)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
                .overlay(alignment: .center) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.white, .black.opacity(0.35))
                        .shadow(radius: 3)
                }
            Text(DetailFormatting.continueWatchingLabel(entry.item))
                .font(.callout).lineLimit(1)
                .frame(width: width, alignment: .leading)
        }
    }
}
