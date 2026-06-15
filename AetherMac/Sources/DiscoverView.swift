import SwiftUI
import AetherCore

/// Horizontal rails across all connected sources. Two modes share the same
/// loaded `UnifiedRails`:
/// - `.home` — Continue Watching, Recently Added/Released, Top Rated.
/// - `.discover` — a featured pick + curated rails (New Releases, Top Rated,
///   Picked for You); watched + in-progress titles are filtered out (#350).
/// Each poster is a `MacPoster` wrapped in a `NavigationLink` to the base
/// `MediaItem` (the shared Detail destination).
struct DiscoverView: View {
    enum Mode { case home, discover }
    let session: MacSession
    var mode: Mode = .discover

    /// Rails are cached on the session (survive sidebar tab switches, which
    /// recreate this view), so a tab click repaints instantly instead of
    /// reloading.
    private var rails: UnifiedRails { session.homeRailsCache }

    var body: some View {
        ScrollView {
            if !rails.isEmpty {
                content
            } else if session.isLoadingRails || !session.didRestore {
                // Starting up (sources still restoring) or actively loading —
                // show the branded animated loader (iOS parity) rather than a
                // static skeleton or a premature "connect a source" empty state,
                // so a slow first load never reads as a frozen window.
                AetherLoadingDots(caption: "Loading your library…")
                    .frame(maxWidth: .infinity, minHeight: 320)
                    .padding(.vertical, 60)
            } else {
                AetherEmptyState(
                    glyph: "sparkles",
                    title: "Nothing here yet",
                    message: "Connect Plex or Jellyfin in Settings to browse your library."
                )
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .cinematicBackground()
        .navigationTitle(mode == .home ? "Home" : "Discover")
        .toolbar {
            // A spinner while a load/refresh is in flight gives feedback even
            // when content is already on screen (the loader only shows over an
            // empty view) — so a background revalidate never looks like a hang.
            ToolbarItem {
                if session.isLoadingRails { ProgressView().controlSize(.small) }
            }
        }
        // Reload when sources change AND after a player records a resume point,
        // so Continue Watching reflects what was just played. The session cache
        // makes this a no-op when nothing changed (instant on tab switch).
        .task(id: "\(session.libraryToken)-\(session.resumeRevision)") {
            await session.loadHomeRailsIfNeeded()
        }
    }

    /// The loaded rails — the real content body.
    @ViewBuilder
    private var content: some View {
        LazyVStack(alignment: .leading, spacing: 32) {
            switch mode {
            case .home:
                continueWatchingRail
                rail("Recently Added", filtered(rails.recentlyAdded))
                rail("Recently Released", filtered(rails.recentlyReleased))
                rail("Top Rated", filtered(topRated))
            case .discover:
                // Curated "what should I watch" rails (#350): genre lanes
                // and the full Movies / TV Shows catalog dumps were removed
                // (Library already browses those + by genre). Discover now
                // mirrors mobile: a featured pick, New Releases, Top Rated,
                // and a serendipitous Picked for You.
                if let featured { featuredHero(featured) }
                rail("New Releases", newReleases)
                rail("Top Rated", filtered(topRated))
                rail("Picked for You", pickedForYou)
            }
        }
        .padding(.vertical, 24)
    }

    /// The spotlight title for Discover — the highest-rated recently-added title
    /// that has a backdrop to show.
    private var featured: UnifiedMediaItem? {
        let pool = filtered(rails.recentlyAdded.isEmpty ? rails.movies : rails.recentlyAdded)
            .filter { $0.backdropURL != nil }
        return pool.max { ($0.communityRating ?? 0) < ($1.communityRating ?? 0) } ?? pool.first
    }

    /// A large cinematic banner: backdrop + gradient scrim, title, metadata, and
    /// Play / More Info — the iOS-style Featured hero.
    @ViewBuilder
    private func featuredHero(_ item: UnifiedMediaItem) -> some View {
        let base = item.preferredSource?.item ?? item.sources.first?.item
        ZStack(alignment: .bottomLeading) {
            CachedAsyncImage(url: item.backdropURL ?? item.posterURL, aspectRatio: 16.0 / 9.0)
                .overlay(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.25), .black.opacity(0.85)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            VStack(alignment: .leading, spacing: 10) {
                Text(item.title).font(.system(size: 34, weight: .bold)).foregroundStyle(.white)
                HStack(spacing: 10) {
                    if let year = item.year { Text(String(year)) }
                    if !item.genres.isEmpty { Text(item.genres.prefix(3).joined(separator: " · ")) }
                    if let r = item.communityRating, r > 0 {
                        Label(String(format: "%.1f", r), systemImage: "star.fill")
                    }
                }
                .font(.callout).foregroundStyle(.white.opacity(0.85))
                HStack(spacing: 12) {
                    if let base {
                        Button { Task { await session.play(base) } } label: {
                            Label("Play", systemImage: "play.fill").frame(width: 110)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        NavigationLink(value: base) {
                            Label("More Info", systemImage: "info.circle")
                        }
                        .buttonStyle(.bordered).controlSize(.large)
                    }
                }
                .padding(.top, 4)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: 1100)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }

    /// In-progress titles (movies + episodes) as landscape cards with a progress
    /// bar — the "pick up where you left off" rail, like the mobile Home.
    @ViewBuilder
    private var continueWatchingRail: some View {
        if !rails.continueWatching.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                AetherSectionHeader(title: "Continue Watching").padding(.horizontal, 24)
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

    /// Drop fully-watched **and** in-progress titles when the user hides them on
    /// discovery surfaces (#280/#350, mobile parity) — Discover shows what's still
    /// ahead; started titles live in Continue Watching. In-progress is matched by
    /// the already-loaded Continue Watching entries' source ids. The Library grid
    /// stays the complete catalog and is never filtered.
    private func filtered(_ items: [UnifiedMediaItem]) -> [UnifiedMediaItem] {
        guard session.playbackPrefs.hideWatchedInDiscovery else { return items }
        let started = inProgressIDs
        return items.filter { item in
            guard !item.isFullyWatched else { return false }
            return !item.sources.contains { started.contains($0.item.id) }
        }
    }

    /// MediaIDs that are in progress (have a resume point) — taken from the
    /// loaded Continue Watching rail, so Discover never double-surfaces a title
    /// the user is mid-way through (movies match exactly; show containers can't,
    /// since Continue Watching keys on the episode).
    private var inProgressIDs: Set<MediaID> {
        Set(rails.continueWatching.map { $0.item.id })
    }

    /// New Releases ("Novinky"): newest by release date, falling back to recently
    /// added when the sources don't carry release dates. Watched/in-progress are
    /// filtered out like every Discover rail.
    private var newReleases: [UnifiedMediaItem] {
        let released = filtered(rails.recentlyReleased)
        return released.isEmpty ? filtered(rails.recentlyAdded) : released
    }

    /// A shuffled grab-bag across the (filtered) catalog — rediscover something
    /// you own but forgot, mirroring mobile's "Picked for You".
    private var pickedForYou: [UnifiedMediaItem] {
        Array(filtered(rails.movies + rails.shows).shuffled().prefix(20))
    }

    /// Highest-rated titles across movies + shows (mobile's "Top Rated" rail).
    private var topRated: [UnifiedMediaItem] {
        (rails.movies + rails.shows)
            .filter { ($0.communityRating ?? 0) > 0 }
            .sorted { ($0.communityRating ?? 0) > ($1.communityRating ?? 0) }
            .prefix(20)
            .map { $0 }
    }

    @ViewBuilder
    private func rail(_ title: String, _ items: [UnifiedMediaItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                AetherSectionHeader(title: title).padding(.horizontal, 24)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 18) {
                        ForEach(items) { item in
                            if let base = item.preferredSource?.item ?? item.sources.first?.item {
                                NavigationLink(value: base) { MacPoster(item: item, width: 150) }
                                    .buttonStyle(.plain)
                            } else {
                                MacPoster(item: item, width: 150)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                }
            }
        }
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
