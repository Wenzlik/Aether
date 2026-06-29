import SwiftUI
import Combine
import AetherCore

/// Horizontal rails across all connected sources. Two modes share the same
/// loaded `UnifiedRails`:
/// - `.home` — Continue Watching, Recently Added/Released, Top Rated.
/// - `.discover` — a rotating featured carousel + curated rails (#381 parity).
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

    // MARK: - Carousel state (#381 macOS parity)

    /// The visible carousel slide index.
    @State private var heroIndex = 0
    /// Counts down seconds until the next auto-advance.
    @State private var advanceCountdown = Self.autoAdvanceInterval
    /// While > 0 the carousel is paused after a manual interaction.
    @State private var pauseCountdown = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let carouselTicker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private static let autoAdvanceInterval = 6
    private static let resumeIdleSeconds = 3

    // MARK: - Netflix discovery

    /// Netflix-only discovery rails (#360) — opt-in, loaded on demand.
    @State private var netflixNew: [UnifiedMediaItem] = []
    @State private var netflixTop: [UnifiedMediaItem] = []

    /// Re-key the Netflix load when the toggle / region / show-only change.
    private var netflixKey: String {
        let p = session.streamingPreferences
        return "\(p.netflixAvailabilityEnabled)-\(p.showNetflixOnlyTitles)-\(p.region ?? "auto")-\(session.libraryToken)"
    }

    var body: some View {
        ScrollView {
            if !rails.isEmpty {
                content
            } else if session.isLoadingRails || !session.didRestore {
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
        .navigationTitle("")
        .toolbar {
            ToolbarItem {
                if session.isLoadingRails { ProgressView().controlSize(.small) }
            }
        }
        .task(id: "\(session.libraryToken)-\(session.resumeRevision)") {
            await session.loadHomeRailsIfNeeded()
        }
        .task(id: netflixKey) { await loadNetflixRails() }
        .onReceive(carouselTicker) { _ in autoAdvanceTick() }
    }

    // MARK: - Hero items (#381)

    /// "Recommended by Aether": taste-based picks, ≤7, no in-progress titles
    /// (those live in Continue Watching) — matching the iOS hero. Taste is learned
    /// from the full library (watched / favourited / highly-rated); the picks are
    /// unwatched and not started. Falls back to best-rated so it's never empty.
    private var heroItems: [UnifiedMediaItem] {
        guard mode == .discover else { return [] }
        let all = rails.movies + rails.shows
        let started = inProgressIDs
        let candidates = all.filter { item in
            !item.isFullyWatched && !item.sources.contains { started.contains($0.item.id) }
        }
        var built = RecommendationEngine().recommended(
            from: candidates, profile: .from(library: all), limit: 7
        )
        // Pad thin taste picks (small / uniform library) so the carousel breathes.
        if built.count < 5 {
            var seen = Set(built.map(\.id))
            for item in candidates.shuffled() where built.count < 5 {
                if seen.insert(item.id).inserted { built.append(item) }
            }
        }
        // Last resort: no unwatched candidates at all — best-rated, never empty.
        if built.isEmpty {
            built = Array(all.sorted {
                ($0.tmdbRating ?? $0.communityRating ?? 0) > ($1.tmdbRating ?? $1.communityRating ?? 0)
            }.prefix(7))
        }
        return built
    }

    /// Progress fraction (0…1) per in-progress hero slide, keyed by the unified
    /// id the carousel looks up (`UnifiedMediaItem.id`).
    private var heroProgress: [String: Double] {
        var result: [String: Double] = [:]
        for entry in rails.continueWatching {
            guard let unified = unified(matching: entry.item),
                  let runtime = entry.item.runtime else { continue }
            let total = DetailFormatting.seconds(runtime)
            guard total > 0 else { continue }
            result[unified.id] = min(1, max(0, DetailFormatting.seconds(entry.resume.position) / total))
        }
        return result
    }

    /// The loaded unified title whose sources include this Continue Watching
    /// `MediaItem`, matched by source id. `nil` when the title isn't in the
    /// capped rails (it then simply sits out of the hero carousel).
    private func unified(matching item: MediaItem) -> UnifiedMediaItem? {
        let pool = rails.movies + rails.shows + rails.recentlyAdded + rails.recentlyReleased
        return pool.first { $0.sources.contains { $0.item.id == item.id } }
    }

    // MARK: - Content body

    @ViewBuilder
    private var content: some View {
        LazyVStack(alignment: .leading, spacing: 40) {
            brandHeader
            switch mode {
            case .home:
                continueWatchingRail
                rail("Recently Added", filtered(rails.recentlyAdded))
                rail("Recently Released", filtered(rails.recentlyReleased))
                rail("Top Rated", filtered(topRated))
            case .discover:
                let items = heroItems
                if !items.isEmpty {
                    heroCarousel(items)
                }
                rail("New Releases", newReleases)
                rail("Top Rated", filtered(topRated))
                rail("Picked for You", pickedForYou)
                if !netflixNew.isEmpty { rail("New on Netflix", netflixNew) }
                if !netflixTop.isEmpty { rail("Top on Netflix", netflixTop) }
            }
        }
        .padding(.vertical, 24)
    }

    // MARK: - Brand header

    /// Centred AETHER wordmark at the top of Home / Discover. The main window has
    /// no wordmark in its chrome (the titlebar carries only the sidebar toggle,
    /// #432), so the brand mark lives here — and it gives the rails room to
    /// breathe instead of starting hard against the toolbar. Only drawn on the
    /// rails path (loading / empty states own their own full-screen layout).
    private var brandHeader: some View {
        Image("AetherBrandMark")
            .resizable()
            .scaledToFit()
            .frame(height: 52)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 8)
            .accessibilityLabel("Aether")
    }

    // MARK: - Rotating carousel (#381 macOS parity)

    /// Eyebrow above the hero — labels the carousel as Aether's taste-based
    /// picks and shows the current slide's "because…" reason.
    private var recommendedEyebrow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Recommended by Aether", systemImage: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            if let reason = currentHeroReason {
                Text(reasonText(reason))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 24)
    }

    /// The "because…" reason for the currently visible hero slide.
    private var currentHeroReason: RecommendationReason? {
        let items = heroItems
        guard heroIndex < items.count else { return nil }
        let all = rails.movies + rails.shows
        let recentlyWatched = all
            .filter { $0.lastWatched != nil }
            .sorted { ($0.lastWatched ?? .distantPast) > ($1.lastWatched ?? .distantPast) }
        return RecommendationReason.make(
            for: items[heroIndex], recentlyWatched: recentlyWatched, profile: .from(library: all)
        )
    }

    private func reasonText(_ reason: RecommendationReason) -> String {
        switch reason {
        case .becauseYouWatched(let title):
            return String(localized: "Because you watched \(title)")
        case .matchesTaste(let genres):
            return String(localized: "Matches your taste for \(genres.joined(separator: " & "))")
        }
    }

    @ViewBuilder
    private func heroCarousel(_ items: [UnifiedMediaItem]) -> some View {
        let idx = min(heroIndex, items.count - 1)
        VStack(alignment: .leading, spacing: 10) {
            // Marks the hero as Aether's own taste-based recommendations.
            recommendedEyebrow
            heroSlide(items[idx], progress: heroProgress[items[idx].id], items: items, currentIndex: idx)
            if items.count > 1 {
                heroPageDots(count: items.count, current: idx)
                    .padding(.horizontal, 24)
            }
        }
    }

    @ViewBuilder
    private func heroSlide(_ item: UnifiedMediaItem, progress: Double?, items: [UnifiedMediaItem], currentIndex: Int) -> some View {
        let base = item.preferredSource?.item ?? item.sources.first?.item
        ZStack(alignment: .bottomLeading) {
            CachedAsyncImage(url: item.backdropURL ?? item.posterURL, aspectRatio: 16.0 / 9.0)
                .overlay(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.25), .black.opacity(0.85)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay(alignment: .bottom) {
                    if let progress {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.white.opacity(0.25))
                                Rectangle()
                                    .fill(AetherMacTheme.accent)
                                    .frame(width: geo.size.width * progress)
                            }
                            .frame(height: 5)
                        }
                        .frame(height: 5)
                    }
                }

            VStack(alignment: .leading, spacing: 10) {
                Text(item.title)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 8, y: 2)
                HStack(spacing: 10) {
                    if let year = item.year { Text(String(year)) }
                    if !item.genres.isEmpty { Text(item.genres.prefix(3).joined(separator: " · ")) }
                    if let r = item.communityRating, r > 0 {
                        Label(String(format: "%.1f", r), systemImage: "star.fill")
                    }
                    if let quality = base?.mediaInfo?.videoResolution {
                        heroBadge(quality)
                    }
                    if base?.mediaInfo?.isDolbyVision == true {
                        heroBadge("Dolby Vision")
                    } else if base?.mediaInfo?.isHDR == true {
                        heroBadge("HDR")
                    }
                }
                .font(.callout).foregroundStyle(.white.opacity(0.85))
                HStack(spacing: 12) {
                    if let base {
                        Button { Task { await session.play(base) } } label: {
                            Label("Play", systemImage: "play.fill").frame(width: 110)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        NavigationLink(value: item) {
                            Label("More Info", systemImage: "info.circle")
                        }
                        .buttonStyle(.bordered).controlSize(.large)
                    }
                }
                .padding(.top, 4)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)

            if items.count > 1 {
                HStack {
                    Button { advanceHero(by: -1, items: items) } label: {
                        Image(systemName: "chevron.left")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(.black.opacity(0.35), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 12)
                    Spacer()
                    Button { advanceHero(by: 1, items: items) } label: {
                        Image(systemName: "chevron.right")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(.black.opacity(0.35), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 12)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .id(item.id)
        .transition(.opacity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: heroIndex)
    }

    private func heroBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(.white.opacity(0.3), lineWidth: 0.75))
    }

    private func heroPageDots(count: Int, current: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(i == current ? AetherMacTheme.accent : Color.white.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.2), value: current)
    }

    private func autoAdvanceTick() {
        let items = heroItems
        guard items.count > 1, !reduceMotion else { return }
        if pauseCountdown > 0 { pauseCountdown -= 1; return }
        advanceCountdown -= 1
        if advanceCountdown <= 0 {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.4)) {
                heroIndex = (heroIndex + 1) % items.count
            }
            advanceCountdown = Self.autoAdvanceInterval
        }
    }

    private func advanceHero(by delta: Int, items: [UnifiedMediaItem]) {
        pauseCountdown = Self.resumeIdleSeconds
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.4)) {
            heroIndex = (heroIndex + delta + items.count) % items.count
        }
        advanceCountdown = Self.autoAdvanceInterval
    }

    // MARK: - Continue Watching rail (home mode)

    /// Continue Watching rail — every in-progress title, most recently active
    /// first. Hidden when there's nothing in progress.
    @ViewBuilder
    private var continueWatchingRail: some View {
        let remaining = rails.continueWatching
        if !remaining.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                AetherSectionHeader(title: "Continue Watching").padding(.horizontal, 24)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 18) {
                        ForEach(remaining) { entry in
                            NavigationLink(value: entry.item) {
                                ContinueWatchingCard(entry: entry)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    Task { await session.play(entry.item) }
                                } label: {
                                    Label("Resume", systemImage: "play.fill")
                                }
                                Divider()
                                Button {
                                    Task {
                                        await session.markWatched(entry.item, watched: true)
                                        await session.clearResume(for: entry.item)
                                    }
                                } label: {
                                    Label("Mark as Watched", systemImage: "checkmark.circle")
                                }
                                Button(role: .destructive) {
                                    Task { await session.removeFromContinueWatching(entry.item) }
                                } label: {
                                    Label("Remove from Continue Watching", systemImage: "minus.circle")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                }
            }
        }
    }

    // MARK: - Netflix

    private func loadNetflixRails() async {
        guard mode == .discover, session.watchAvailability.showsNetflixOnly else {
            netflixNew = []; netflixTop = []
            return
        }
        let owned = Set((rails.movies + rails.shows).compactMap(\.tmdbID))
        func unowned(_ items: [UnifiedMediaItem]) -> [UnifiedMediaItem] {
            Array(items.filter { $0.tmdbID.map { !owned.contains($0) } ?? true }.prefix(12))
        }
        netflixNew = unowned(await session.watchAvailability.netflixOnlyDiscover(isShow: false, sort: .newest))
        netflixTop = unowned(await session.watchAvailability.netflixOnlyDiscover(isShow: false, sort: .topRated))
    }

    // MARK: - Filtering helpers

    private func filtered(_ items: [UnifiedMediaItem]) -> [UnifiedMediaItem] {
        guard session.playbackPrefs.hideWatchedInDiscovery else { return items }
        let started = inProgressIDs
        return items.filter { item in
            guard !item.isFullyWatched else { return false }
            return !item.sources.contains { started.contains($0.item.id) }
        }
    }

    private var inProgressIDs: Set<MediaID> {
        Set(rails.continueWatching.map { $0.item.id })
    }

    private var newReleases: [UnifiedMediaItem] {
        let released = filtered(rails.recentlyReleased)
        return released.isEmpty ? filtered(rails.recentlyAdded) : released
    }

    private var pickedForYou: [UnifiedMediaItem] {
        Array(filtered(rails.movies + rails.shows).shuffled().prefix(20))
    }

    private var topRated: [UnifiedMediaItem] {
        (rails.movies + rails.shows)
            .filter { ($0.communityRating ?? 0) > 0 }
            .sorted { ($0.communityRating ?? 0) > ($1.communityRating ?? 0) }
            .prefix(20)
            .map { $0 }
    }

    // MARK: - Rail

    @ViewBuilder
    private func rail(_ title: String, _ items: [UnifiedMediaItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                AetherSectionHeader(title: title).padding(.horizontal, 24)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 20) {
                        ForEach(items) { item in
                            if let base = item.preferredSource?.item ?? item.sources.first?.item {
                                NavigationLink(value: item) { MacPoster(item: item, width: 170) }
                                    .buttonStyle(.plain)
                                    .contextMenu { railContextMenu(item, base: base) }
                            } else {
                                MacPoster(item: item, width: 170)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                }
            }
        }
    }

    @ViewBuilder
    private func railContextMenu(_ item: UnifiedMediaItem, base: MediaItem) -> some View {
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
}

/// A landscape Continue Watching card: backdrop still, a resume progress bar,
/// and a title line that names the episode (`Show · S1E2 · …`) when relevant.
private struct ContinueWatchingCard: View {
    let entry: HomeFeed.ContinueWatchingEntry
    private let width: CGFloat = 264
    @State private var isHovered = false

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
        .scaleEffect(isHovered ? 1.04 : 1.0, anchor: .bottom)
        .animation(.spring(response: 0.22, dampingFraction: 0.82), value: isHovered)
        .onHover { isHovered = $0 }
    }
}
