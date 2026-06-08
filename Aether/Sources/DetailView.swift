import SwiftUI
#if canImport(UIKit)
import UIKit   // UIViewController / UIHostingController for the visionOS cinema Info-panel tab
#endif
import AetherCore

struct DetailView: View {
    let item: MediaItem
    /// Every connected source. The connector this screen uses is derived from
    /// the *shown item's* source (see `source`), so a title opened from the
    /// unified Home/Search plays through the right server even when it isn't the
    /// app's active source.
    let connectedSources: [any MediaSource]
    let resumeStore: ResumeStore
    let playbackSession: PlaybackSession
    /// `nil` until `AppSession.start()` has booted the downloads pipeline.
    /// Views guard with `if let manager` so a pre-boot Detail still works
    /// (Play / Resume) — just no Download button.
    let downloadManager: DownloadManager?
    /// `@MainActor`-bound mirror of the store. Reads
    /// `downloads.snapshot.status(for:)` synchronously in `body`. `nil`
    /// until boot completes for the same reason as `downloadManager`.
    let downloads: DownloadObserver?
    /// App-wide playback defaults (Default Quality / Audio Language /
    /// Subtitle Language). When the user opens a title, the Audio /
    /// Subtitles / Quality pickers pre-select matching values from these
    /// defaults so playback starts how the user said they want it.
    /// `nil` only in test fixtures or pre-boot paths.
    let playbackPreferences: PlaybackPreferencesStore?
    /// Every source that has this title, sorted by priority — populated only
    /// when Detail is reached from the unified feed (Home / Search navigate a
    /// `UnifiedMediaItem`). Drives the "Available Sources" section + manual
    /// source override. Empty for single-source contexts (Library / Discover /
    /// Continue Watching), where the section is hidden.
    /// (`var` with a default so it stays in the memberwise init — a `let` with a
    /// default would be dropped from it.)
    var availableSources: [UnifiedSource] = []

    @State private var resume: ResumePoint?
    /// The source the user manually switched to via "Available Sources". `nil`
    /// = use the title's preferred source (the navigated `item`). Everything
    /// playback-related (`current`, `source`, hydration, downloads, resume,
    /// children) follows `activeItem`, so switching swaps the whole screen to
    /// the chosen server without re-navigating.
    @State private var overrideItem: MediaItem?
    /// Optimistic watched state for the manual toggle — overrides the hydrated
    /// item's server value so the UI flips instantly. `nil` = use the item's own
    /// `isWatched`. Reset when the active source changes.
    @State private var watchedOverride: Bool?
    @State private var isPlayerPresented = false
    @State private var playbackItem: MediaItem?
    /// Where the presented player should begin. `nil` resumes from the saved
    /// point ("Resume"); `0` forces a restart ("Play From Beginning").
    @State private var playbackStartAt: Double?
    @State private var isPreparingPlayback = false
    /// visionOS: the current player presentation was launched via "Watch in
    /// Cinema" → auto-expand so it docks into the Dark Theater without a tap.
    @State private var launchingInCinema = false
    @State private var children: [MediaItem] = []
    @State private var isLoadingChildren = false
    /// Similar titles for the "More Like This" rail (source recommendations).
    @State private var related: [MediaItem] = []
    /// Series detail only — the season the inline episode list is showing.
    /// Defaults to the first season once `children` (the show's seasons) load.
    @State private var selectedSeason: MediaItem?
    /// Episodes of `selectedSeason`, shown inline (no navigation into a season).
    @State private var seasonEpisodes: [MediaItem] = []
    @State private var isLoadingEpisodes = false
    /// The series "On Deck" episode — the next one to watch across the *whole*
    /// show (the first unwatched episode of the first not-fully-watched season).
    /// Computed once on load and stays put while the user browses other seasons.
    @State private var nextUpEpisode: MediaItem?
    /// Saved resume position for the On Deck episode, when one exists — drives
    /// the "Resume from m:ss" caption on the Next Up card.
    @State private var nextUpResume: ResumePoint?
    /// The item with full metadata (audio + subtitle streams, partID,
    /// mediaInfo) once hydrated, carrying the user's audio / subtitle / quality
    /// choices. Playback decisions happen here on Detail, before the player
    /// opens — the configured item is what launches. `nil` until the detail
    /// endpoint resolves; `current` falls back to the list `item`.
    @State private var configuredItem: MediaItem?
    /// Which compact selector sheet is currently presented on Detail. `nil`
    /// = nothing open; tapping a disclosure row sets one. iOS / iPadOS uses
    /// `.presentationDetents([.medium])` so the picker takes about half the
    /// screen and the Detail backdrop is still visible behind.
    @State private var presentedSelector: PlaybackSelector?
    /// True while a Download is being prepared (quality picker → enqueue) so
    /// the button can read "Starting…" and disable.
    @State private var isEnqueuingDownload = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Drives the backdrop layout: compact (iPhone) → full-width 16:9; regular
    /// (iPad / tvOS / visionOS) → edge-to-edge fill at a fixed height.
    @Environment(\.horizontalSizeClass) private var hSizeClass
    #if os(visionOS)
    /// Cinema Mode state — drives the "Watch in Cinema" entry. Injected at the
    /// app root; always present inside the windowed view tree on visionOS.
    @Environment(CinemaManager.self) private var cinema
    /// Re-dock signal for the docked player (size/seat changed live in-cinema).
    private var cinemaRedockToken: UUID? { cinema.redockToken }
    /// Builds the Screen-size + Seat controls as a tab in the native player's Info
    /// panel (`customInfoViewControllers`). Only for a Cinema launch; windowed
    /// playback gets no cinema tab. A maker closure (run once, in
    /// `makeUIViewController`) returning a `UIHostingController` whose SwiftUI
    /// content observes `cinema` for live selection + writes back on tap. Captures
    /// `cinema` (the reference), not `self`.
    private var makeCinemaInfoControllers: (() -> [UIViewController])? {
        guard launchingInCinema else { return nil }
        let cinema = self.cinema
        return {
            let host = UIHostingController(rootView: CinemaInfoControls(cinema: cinema))
            host.title = "Theater"
            host.preferredContentSize = CGSize(width: 480, height: 260)
            host.view.backgroundColor = .clear   // let the Info panel material show through
            return [host]
        }
    }
    #else
    private var cinemaRedockToken: UUID? { nil }
    private var makeCinemaInfoControllers: (() -> [UIViewController])? { nil }
    #endif

    /// Which selector sheet is open. Audio / Subtitles / Quality are the
    /// playback configuration triplet; `downloadQuality` reuses the same
    /// sheet pattern but enqueues a download instead of recording a
    /// selection on the item.
    private enum PlaybackSelector: Identifiable {
        case audio, subtitles, quality, downloadQuality, technicalDetails
        var id: String {
            switch self {
            case .audio: return "audio"
            case .subtitles: return "subtitles"
            case .quality: return "quality"
            case .downloadQuality: return "downloadQuality"
            case .technicalDetails: return "technicalDetails"
            }
        }
    }

    /// The source the screen is currently acting on — the manually-selected
    /// override, or the navigated `item` (the title's preferred source). All
    /// playback-related state derives from this, so an "Available Sources"
    /// switch re-points hydration / playback / downloads at the chosen server.
    private var activeItem: MediaItem { overrideItem ?? item }

    /// The item reflecting hydration + the user's track / quality selections.
    private var current: MediaItem { configuredItem ?? activeItem }

    /// The connector for the shown item — matched by the item's source id, so
    /// playback / hydration / downloads use the correct server even when the
    /// item came from the unified feed and isn't the app's active source. Falls
    /// back to the first connected source.
    private var source: (any MediaSource)? {
        connectedSources.first { $0.id == activeItem.id.source } ?? connectedSources.first
    }

    /// Download status for this item. `.notDownloaded` when the pipeline
    /// hasn't booted yet — same surface as "no job recorded" so the UI
    /// renders identically.
    private var downloadStatus: DownloadStatus {
        downloads?.status(for: activeItem.id) ?? .notDownloaded
    }

    var body: some View {
        ZStack {
            GeometryReader { geo in
                Group {
                    if isShow {
                        // Shows use the stacked series layout (Next Up → seasons →
                        // episodes); the cinematic hero is movie-oriented.
                        scrollContent
                    } else if item.kind == .movie {
                        // Movies get the cinematic hero on every platform — the
                        // backdrop is the screen, content embedded over it.
                        movieContent(geo.size)
                    } else if isWideLayout(geo.size) {
                        // Episodes (and other non-movie playables) keep the
                        // responsive wide / stacked split.
                        wideContent
                    } else {
                        scrollContent
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .opacity(isPlayerPresented ? 0 : 1)

            if isPlayerPresented {
                PlayerView(
                    item: playbackItem ?? activeItem,
                    source: source,
                    session: playbackSession,
                    startAt: playbackStartAt,
                    preferExpanded: launchingInCinema,
                    redockToken: cinemaRedockToken,
                    makeCinemaInfoControllers: makeCinemaInfoControllers,
                    playbackPreferences: playbackPreferences,
                    onDismiss: dismissPlayer
                )
                .transition(.opacity)
                .zIndex(10)
                #if os(iOS)
                .statusBarHidden()
                #endif
            }
        }
        .aetherScreenBackground()
        #if os(iOS)
        .toolbar(isPlayerPresented ? .hidden : .automatic, for: .navigationBar)
        #endif
        .toolbar(isPlayerPresented ? .hidden : .automatic, for: .tabBar)
        // Keyed on the active item: re-runs when the user switches source via
        // "Available Sources", re-hydrating + reloading resume/children for the
        // newly-selected server.
        .task(id: activeItem.id) {
            resume = await resumeStore.point(for: activeItem.id)
            await hydrateForPlayback()
            await loadChildrenIfNeeded()
            await setupSeasonsIfNeeded()
            related = await source?.related(to: activeItem.id) ?? []
        }
        .animation(reduceMotion ? nil : AetherDesign.Motion.hero, value: isPlayerPresented)
        .sheet(item: $presentedSelector) { selector in
            // Use the closure parameter, not the @State again. On first
            // presentation SwiftUI evaluates the sheet body before the
            // @State write has propagated through, so reading
            // `presentedSelector` inside `playbackSelectorSheet` hits
            // the stale `nil` value, the switch falls into `case .none`,
            // and the user sees an empty sheet. Reopening works because
            // by then @State is settled. The closure parameter is the
            // snapshot at presentation — always non-nil, always
            // correct.
            playbackSelectorSheet(for: selector)
        }
        #if os(visionOS)
        .onChange(of: cinema.isActive) { _, active in
            // Cinema ended (movie finished or the Dark Theater was dismissed) —
            // drop the player overlay so we don't leave a stale player behind.
            guard !active, isPlayerPresented else { return }
            withAnimation(reduceMotion ? nil : AetherDesign.Motion.hero) {
                isPlayerPresented = false
            }
            playbackItem = nil
            Task { resume = await resumeStore.point(for: activeItem.id) }
        }
        #endif
    }

    // MARK: - Detail content

    private var scrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                // Hero: edge-to-edge backdrop with the title + metadata + badges
                // stacked *below* it (not overlaid), so wide layouts don't push
                // the text into a side gutter beside a letterboxed image.
                VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
                    BackdropImage(
                        url: item.backdropURL(.backdrop) ?? item.posterURL(.detail),
                        height: hSizeClass == .regular ? backdropMaxHeight : nil
                    )

                    VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
                        Text(item.title)
                            .font(AetherDesign.Typography.heroTitle)
                            .foregroundStyle(AetherDesign.Palette.textPrimary)
                        metadataRow
                        mediaBadges
                    }
                    .padding(.horizontal, AetherDesign.Spacing.l)
                }

                if isShow {
                    // Dedicated TV-show layout: Next Up → Season Selector →
                    // Episodes → Overview → Details.
                    seriesContent
                        .padding(.horizontal, AetherDesign.Spacing.l)
                } else {
                    // Layout order (Apple-TV / Infuse style): Hero → Actions →
                    // Playback → Overview → Media Information → (children).
                    if !item.kind.isContainer {
                        actionRow
                            .padding(.horizontal, AetherDesign.Spacing.l)
                    }

                    if !item.kind.isContainer, current.streamURL != nil {
                        playbackSection
                            .padding(.horizontal, AetherDesign.Spacing.l)
                            .frame(maxWidth: 720, alignment: .leading)
                    }

                    if let summary = item.summary {
                        Text(summary)
                            .font(AetherDesign.Typography.body)
                            .foregroundStyle(AetherDesign.Palette.textSecondary)
                            .padding(.horizontal, AetherDesign.Spacing.l)
                            .frame(maxWidth: 720, alignment: .leading)
                    }

                    if !item.kind.isContainer, current.mediaInfo != nil {
                        mediaSection
                            .padding(.horizontal, AetherDesign.Spacing.l)
                            .frame(maxWidth: 720, alignment: .leading)
                    }

                    // Only meaningful when the title exists on more than one source.
                    if availableSources.count > 1 {
                        availableSourcesSection
                            .padding(.horizontal, AetherDesign.Spacing.l)
                            .frame(maxWidth: 720, alignment: .leading)
                    }

                    // Season detail (browsed into directly): episode list.
                    if item.kind.isContainer {
                        childrenSection
                            .padding(.horizontal, AetherDesign.Spacing.l)
                    }
                }
            }
            .padding(.bottom, AetherDesign.Spacing.xxl)
        }
    }

    // MARK: - Wide hero layout (tvOS / landscape / visionOS wide)

    /// Wide when the surface is landscape-ish and roomy: tvOS always; iPad
    /// landscape, iPhone landscape, and wide visionOS windows. iPhone/iPad
    /// portrait fall back to the vertical `scrollContent`.
    private func isWideLayout(_ size: CGSize) -> Bool {
        #if os(tvOS)
        return true
        #else
        return size.width > size.height && size.width >= 600
        #endif
    }

    /// Apple-TV / Infuse-style detail: the backdrop fills the background; a
    /// dark scrim keeps the left content column readable; title, actions,
    /// overview and the playback rows sit on top, visible immediately.
    private var wideContent: some View {
        ZStack(alignment: .topLeading) {
            CachedAsyncImage(
                url: item.backdropURL(heroBackdropTier) ?? item.posterURL(.detail),
                maxPixel: heroBackdropTier.maxPixel
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .overlay { wideScrim }
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                    Text(item.title)
                        .font(AetherDesign.Typography.heroTitle)
                        .foregroundStyle(AetherDesign.Palette.textPrimary)
                    metadataRow
                    mediaBadges

                    if !item.kind.isContainer {
                        actionRow
                    }

                    if let summary = item.summary {
                        Text(summary)
                            .font(AetherDesign.Typography.body)
                            .foregroundStyle(AetherDesign.Palette.textSecondary)
                            .lineLimit(item.kind.isContainer ? 3 : 6)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !item.kind.isContainer, current.streamURL != nil {
                        playbackSection
                    }
                    if !item.kind.isContainer, current.mediaInfo != nil {
                        mediaSection
                    }
                    if availableSources.count > 1 {
                        availableSourcesSection
                    }
                    if item.kind.isContainer {
                        childrenSection
                    }
                }
                .frame(maxWidth: wideColumnWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AetherDesign.Spacing.xl)
                .padding(.top, AetherDesign.Spacing.xl)
                .padding(.bottom, AetherDesign.Spacing.xxl)
            }
        }
    }

    /// Left-anchored content column width on wide layouts — the artwork shows
    /// through on the trailing side, the text stays readable on the leading.
    private var wideColumnWidth: CGFloat {
        #if os(tvOS)
        820
        #else
        640
        #endif
    }

    /// Dark gradient over the backdrop: strong on the leading edge (where the
    /// content column lives) and along the bottom, fading toward the trailing
    /// artwork so the image still reads.
    private var wideScrim: some View {
        ZStack {
            LinearGradient(
                colors: [
                    AetherDesign.Palette.background.opacity(0.92),
                    AetherDesign.Palette.background.opacity(0.55),
                    AetherDesign.Palette.background.opacity(0.08)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            LinearGradient(
                colors: [
                    AetherDesign.Palette.background.opacity(0.75),
                    AetherDesign.Palette.background.opacity(0.0)
                ],
                startPoint: .bottom,
                endPoint: .center
            )
        }
        .ignoresSafeArea()
    }

    /// The server-resize tier for the full-screen hero backdrop. tvOS / visionOS
    /// fill a large display, so they request a 1080p tier; phone / iPad use the
    /// regular backdrop. Pair with `maxPixel` so the local cache doesn't shrink
    /// the large tier back down.
    private var heroBackdropTier: ArtworkTier {
        #if os(tvOS) || os(visionOS)
        return .backdropLarge
        #else
        return .backdrop
        #endif
    }

    private var backdropMaxHeight: CGFloat {
        // Shows put their seasons rail directly below the hero. On tvOS the only
        // way to scroll is to move focus onto a focusable element (a season
        // card), so a tall backdrop that pushes the seasons off-screen traps
        // focus entirely — the user can't move, and Menu exits the app. Use a
        // shorter backdrop for containers (shows) so the seasons sit on-screen
        // and are reachable on first appearance. Movies keep the full hero.
        let isContainer = item.kind.isContainer
        #if os(tvOS)
        return isContainer ? 300 : 560
        #else
        return isContainer ? 240 : 420
        #endif
    }

    // MARK: - Movie layout (cinematic hero, every platform)

    /// The redesigned movie screen: a full-bleed backdrop hero with the title,
    /// metadata, source + capability badges, a short overview and the primary
    /// actions embedded over it — content-first, configuration second. Playback
    /// settings sit *below* the hero (most users never touch them), and the
    /// technical readout moves into the "More" menu.
    private func movieContent(_ size: CGSize) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                movieHero(size)

                // Below the fold: discovery first, then configuration (kept
                // secondary — most users never touch playback settings).
                VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                    relatedRail
                    if current.streamURL != nil {
                        playbackSection
                            .frame(maxWidth: 720, alignment: .leading)
                    }
                    if availableSources.count > 1 {
                        availableSourcesSection
                            .frame(maxWidth: 720, alignment: .leading)
                    }
                }
                .padding(.horizontal, AetherDesign.Spacing.l)
            }
            .padding(.bottom, AetherDesign.Spacing.xxl)
        }
    }

    private func movieHero(_ size: CGSize) -> some View {
        ZStack(alignment: .bottomLeading) {
            CachedAsyncImage(
                url: activeItem.backdropURL(heroBackdropTier) ?? activeItem.posterURL(.detail),
                maxPixel: heroBackdropTier.maxPixel
            )
                .frame(width: size.width, height: movieHeroHeight(size))
                .clipped()
                .overlay { movieHeroScrim }

            VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
                Text(item.title)
                    .font(AetherDesign.Typography.heroTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)

                HStack(spacing: AetherDesign.Spacing.s) {
                    Text(metadataParts.joined(separator: " • "))
                        .font(AetherDesign.Typography.metadata)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                    sourceBadge
                    Spacer(minLength: 0)
                }

                mediaBadges

                if let summary = item.summary {
                    Text(summary)
                        .font(AetherDesign.Typography.body)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                actionRow
            }
            .padding(AetherDesign.Spacing.l)
            .frame(maxWidth: movieHeroContentWidth, alignment: .leading)
        }
        .frame(width: size.width, height: movieHeroHeight(size), alignment: .bottomLeading)
    }

    /// Bottom-anchored dark gradient — keeps the embedded content readable in
    /// both portrait and landscape (unlike the wide layout's leading scrim).
    private var movieHeroScrim: some View {
        LinearGradient(
            colors: [
                .clear,
                AetherDesign.Palette.background.opacity(0.55),
                AetherDesign.Palette.background.opacity(0.96)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Hero height: most of the screen on tvOS / landscape (cinematic), a tall
    /// upper portion in portrait so the content still hints at scroll below.
    private func movieHeroHeight(_ size: CGSize) -> CGFloat {
        #if os(tvOS)
        return size.height * 0.80
        #else
        return size.width > size.height ? size.height * 0.82 : size.height * 0.60
        #endif
    }

    /// Cap the embedded content column on roomy surfaces so lines stay readable;
    /// fills the width on a phone.
    private var movieHeroContentWidth: CGFloat {
        #if os(tvOS)
        900
        #else
        640
        #endif
    }

    // MARK: - More Like This

    /// Source-recommended similar titles. Each card navigates the per-source
    /// `MediaItem`, opening its own Detail. Hidden when the source returns none.
    @ViewBuilder
    private var relatedRail: some View {
        if !related.isEmpty {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
                Text("More Like This")
                    .font(AetherDesign.Typography.sectionTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: AetherDesign.Spacing.l) {
                        ForEach(related) { rel in
                            NavigationLink(value: rel) {
                                AetherCard.poster(
                                    title: rel.title,
                                    posterURL: rel.posterURL,
                                    isWatched: rel.isWatched
                                )
                                .frame(width: relatedPosterWidth)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, AetherDesign.Spacing.xs)
                }
                .aetherDetailFocusSection()
            }
        }
    }

    private var relatedPosterWidth: CGFloat {
        #if os(tvOS)
        220
        #else
        120
        #endif
    }

    // MARK: - Children (seasons / episodes)

    @ViewBuilder
    private var childrenSection: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            Text(childrenTitle)
                .font(AetherDesign.Typography.sectionTitle)
                .foregroundStyle(AetherDesign.Palette.textPrimary)

            if isLoadingChildren {
                AetherLoadingState(.inline)
            } else if children.isEmpty {
                Text("Nothing here yet.")
                    .font(AetherDesign.Typography.body)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
            } else if item.kind == .show {
                seasonsRail
            } else {
                episodesList
            }
        }
    }

    private var childrenTitle: String {
        item.kind == .show ? "Seasons" : "Episodes"
    }

    private var seasonsRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: AetherDesign.Spacing.m) {
                ForEach(children) { season in
                    NavigationLink(value: season) {
                        AetherCard.poster(title: season.title, posterURL: season.posterURL)
                            .frame(width: 140)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, AetherDesign.Spacing.xs)
        }
        // tvOS: mark the horizontal rail as a focus section so Up escapes it
        // back to the tab bar (there's no focusable element above it on a show
        // detail). Without this, focus is trapped in the rail. Matches the
        // Home / Library rails; the episodes list is vertical so it doesn't need it.
        .aetherDetailFocusSection()
    }

    private var episodesList: some View {
        LazyVStack(spacing: AetherDesign.Spacing.m) {
            ForEach(children) { episode in
                NavigationLink(value: episode) {
                    episodeRow(episode)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func episodeRow(_ episode: MediaItem) -> some View {
        HStack(alignment: .top, spacing: AetherDesign.Spacing.m) {
            CachedAsyncImage(
                url: episode.backdropURL(.still) ?? episode.posterURL(.thumbnail),
                aspectRatio: 16.0 / 9.0,
                maxPixel: ArtworkTier.still.maxPixel
            )
                .frame(width: 150)
                .clipShape(RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if episode.isWatched {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.white, AetherDesign.Palette.accent)
                            .font(.system(size: 18, weight: .bold))
                            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                            .padding(AetherDesign.Spacing.xs)
                    }
                }

            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xxs) {
                Text(episode.title)
                    .font(AetherDesign.Typography.cardTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                    .lineLimit(2)
                if let runtime = episode.runtime {
                    Text(formatRuntime(runtime))
                        .font(AetherDesign.Typography.caption)
                        .foregroundStyle(AetherDesign.Palette.textTertiary)
                }
                if let summary = episode.summary {
                    Text(summary)
                        .font(AetherDesign.Typography.caption)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func loadChildrenIfNeeded() async {
        guard activeItem.kind.isContainer, let source, children.isEmpty else { return }
        isLoadingChildren = true
        defer { isLoadingChildren = false }
        do {
            children = try await source.children(of: activeItem.id)
        } catch {
            children = []
        }
    }

    // MARK: - Series layout (Next Up → Season Selector → Episodes → Details)

    /// The dedicated TV-show body. `children` here are the show's *seasons*; the
    /// selected season's episodes live in `seasonEpisodes` and render inline, so
    /// the user never navigates into a season just to see its episodes.
    @ViewBuilder
    private var seriesContent: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
            if isLoadingChildren && children.isEmpty {
                AetherLoadingState(.inline)
            } else {
                nextUpCard
                if children.count > 1 {
                    seasonSelector
                }
                seasonEpisodesSection
                if let summary = item.summary {
                    Text(summary)
                        .font(AetherDesign.Typography.body)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 720, alignment: .leading)
                }
                relatedRail
                seriesDetailsSection
                if availableSources.count > 1 {
                    availableSourcesSection
                        .frame(maxWidth: 720, alignment: .leading)
                }
            }
        }
    }

    /// "On Deck"-style card: thumbnail + episode code + title, with a resume
    /// caption when there's a saved position. Tapping opens the episode's detail
    /// (where Resume / Play / Download already live), so playback stays on the
    /// well-tested episode path.
    @ViewBuilder
    private var nextUpCard: some View {
        if let episode = nextUpEpisode {
            NavigationLink(value: episode) {
                HStack(spacing: AetherDesign.Spacing.m) {
                    CachedAsyncImage(
                        url: episode.backdropURL(.still) ?? episode.posterURL(.thumbnail),
                        aspectRatio: 16.0 / 9.0,
                        maxPixel: ArtworkTier.still.maxPixel
                    )
                        .frame(width: 160)
                        .clipShape(RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous))

                    VStack(alignment: .leading, spacing: AetherDesign.Spacing.xxs) {
                        Text(nextUpResume != nil ? "CONTINUE WATCHING" : "NEXT UP")
                            .font(AetherDesign.Typography.caption)
                            .foregroundStyle(AetherDesign.Palette.accent)
                        Text(episodeLabel(episode))
                            .font(AetherDesign.Typography.cardTitle)
                            .foregroundStyle(AetherDesign.Palette.textPrimary)
                            .lineLimit(2)
                        if let resume = nextUpResume {
                            Text("Resume from \(formatPosition(resume.position))")
                                .font(AetherDesign.Typography.caption)
                                .foregroundStyle(AetherDesign.Palette.textSecondary)
                        } else if let runtime = episode.runtime {
                            Text(formatRuntime(runtime))
                                .font(AetherDesign.Typography.caption)
                                .foregroundStyle(AetherDesign.Palette.textTertiary)
                        }
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(AetherDesign.Palette.accent)
                }
                .padding(AetherDesign.Spacing.m)
                .background(
                    AetherDesign.Palette.surface,
                    in: RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 720, alignment: .leading)
            // tvOS: isolate so Up exits to the tab bar and Down reaches the
            // season selector / episodes instead of trapping focus.
            .aetherDetailFocusSection()
        }
    }

    /// Horizontal capsule chips, one per season — selecting one swaps the inline
    /// episode list without navigating. Scrolls when a show has many seasons.
    private var seasonSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AetherDesign.Spacing.s) {
                ForEach(children) { season in
                    let isSelected = season.id == selectedSeason?.id
                    Button {
                        selectSeason(season)
                    } label: {
                        Text(seasonLabel(season))
                            .font(AetherDesign.Typography.metadata)
                            .padding(.horizontal, AetherDesign.Spacing.m)
                            .padding(.vertical, AetherDesign.Spacing.xs)
                            .background(
                                isSelected ? AetherDesign.Palette.accent : AetherDesign.Palette.surfaceElevated,
                                in: Capsule()
                            )
                            .foregroundStyle(
                                isSelected ? Color.white : AetherDesign.Palette.textSecondary
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, AetherDesign.Spacing.xxs)
        }
        .aetherDetailFocusSection()
    }

    private func seasonLabel(_ season: MediaItem) -> String {
        if let number = season.seasonNumber { return "Season \(number)" }
        return season.title
    }

    @ViewBuilder
    private var seasonEpisodesSection: some View {
        if isLoadingEpisodes {
            AetherLoadingState(.inline)
        } else if !seasonEpisodes.isEmpty {
            LazyVStack(spacing: AetherDesign.Spacing.m) {
                ForEach(seasonEpisodes) { episode in
                    NavigationLink(value: episode) {
                        episodeRow(episode)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func episodeLabel(_ episode: MediaItem) -> String {
        if let season = episode.seasonNumber, let number = episode.episodeNumber {
            return "S\(season)E\(number) · \(episode.title)"
        }
        return episode.title
    }

    /// The "Metadata" block: genres, rating, first-aired, status — surfaced now
    /// that both connectors plumb them through. Hidden entirely when empty.
    @ViewBuilder
    private var seriesDetailsSection: some View {
        let rows = seriesDetailRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.s) {
                Text("Details")
                    .font(AetherDesign.Typography.sectionTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                ForEach(rows, id: \.label) { row in
                    HStack(alignment: .top, spacing: AetherDesign.Spacing.m) {
                        Text(row.label)
                            .foregroundStyle(AetherDesign.Palette.textTertiary)
                            .frame(width: 110, alignment: .leading)
                        Text(row.value)
                            .foregroundStyle(AetherDesign.Palette.textSecondary)
                        Spacer(minLength: 0)
                    }
                    .font(AetherDesign.Typography.body)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    private var seriesDetailRows: [(label: String, value: String)] {
        let show = current
        var rows: [(label: String, value: String)] = []
        if !show.genres.isEmpty {
            rows.append((label: "Genres", value: show.genres.joined(separator: ", ")))
        }
        if let rating = show.communityRating {
            rows.append((label: "Rating", value: String(format: "%.1f", rating)))
        }
        if let aired = firstAiredText(show) {
            rows.append((label: "First Aired", value: aired))
        }
        if let status = seriesStatusText(show) {
            rows.append((label: "Status", value: status))
        }
        return rows
    }

    private func firstAiredText(_ show: MediaItem) -> String? {
        guard let date = show.releaseDate else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    private func seriesStatusText(_ show: MediaItem) -> String? {
        if show.isContinuing == true { return "Continuing" }
        if show.isContinuing == false || show.endYear != nil { return "Ended" }
        return nil
    }

    // MARK: - Series loading

    /// Once the show's seasons (`children`) load, default browsing to the season
    /// the user is actually in — the first season with unwatched episodes (true
    /// On Deck), via the per-season `unwatchedEpisodeCount` — instead of always
    /// Season 1. Then compute the series' Next Up from that season's episodes.
    /// Idempotent — only runs while no season is selected, so re-running the
    /// `.task` after hydration doesn't reset the user's manual season choice.
    private func setupSeasonsIfNeeded() async {
        guard isShow, selectedSeason == nil, !children.isEmpty else { return }
        let deck = children.first { ($0.unwatchedEpisodeCount ?? 0) > 0 } ?? children.first
        selectedSeason = deck
        guard let deck else { return }
        await loadSeasonEpisodes(deck)
        await computeNextUp(from: seasonEpisodes)
    }

    /// The series On Deck episode + its resume point, derived from the deck
    /// season's episodes. Stays fixed while the user browses other seasons, so
    /// the Next Up card always points at where they left off in the show.
    private func computeNextUp(from episodes: [MediaItem]) async {
        guard let candidate = episodes.first(where: { !$0.isWatched }) else {
            nextUpEpisode = nil
            nextUpResume = nil
            return
        }
        nextUpEpisode = candidate
        nextUpResume = await resumeStore.point(for: candidate.id)
    }

    private func selectSeason(_ season: MediaItem) {
        guard season.id != selectedSeason?.id else { return }
        selectedSeason = season
        seasonEpisodes = []
        // Note: the Next Up card tracks the whole series, so it deliberately
        // stays put when the user browses to a different season.
        Task { await loadSeasonEpisodes(season) }
    }

    private func loadSeasonEpisodes(_ season: MediaItem) async {
        guard let source else { return }
        isLoadingEpisodes = true
        defer { isLoadingEpisodes = false }
        do {
            let episodes = try await source.children(of: season.id)
            // Bail if the user switched seasons while this was in flight.
            guard selectedSeason?.id == season.id else { return }
            seasonEpisodes = episodes
        } catch {
            guard selectedSeason?.id == season.id else { return }
            seasonEpisodes = []
        }
    }

    /// "2025 • 1h 59m • Movie" — year · runtime · kind, dot-separated. Runtime
    /// is always included when known, on every layout.
    private var metadataRow: some View {
        Text(metadataParts.joined(separator: " • "))
            .font(AetherDesign.Typography.metadata)
            .foregroundStyle(AetherDesign.Palette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metadataParts: [String] {
        // Shows describe themselves by run span + season/episode counts, not a
        // single runtime: "2011–Present • 8 Seasons • 73 Episodes • Series".
        if item.kind == .show { return seriesMetadataParts }
        var parts: [String] = []
        if let year = item.year { parts.append(String(year)) }
        if let runtime = item.runtime { parts.append(formatRuntime(runtime)) }
        parts.append(kindLabel(item.kind))
        return parts
    }

    /// Series metadata line. Reads `current` so the hydrated counts/status fill
    /// in after the detail endpoint resolves (the navigated list item often
    /// lacks them).
    private var seriesMetadataParts: [String] {
        let show = current
        var parts: [String] = []
        if let years = seriesYearText(show) { parts.append(years) }
        if let seasons = show.seasonCount, seasons > 0 {
            parts.append("\(seasons) Season\(seasons == 1 ? "" : "s")")
        }
        if let episodes = show.episodeCount, episodes > 0 {
            parts.append("\(episodes) Episode\(episodes == 1 ? "" : "s")")
        }
        parts.append("Series")
        return parts
    }

    /// "2011–2019" (ended), "2011–Present" (known continuing), or just "2011"
    /// when the end is unknown — Plex doesn't expose a status, so we never guess
    /// "Present" for it.
    private func seriesYearText(_ show: MediaItem) -> String? {
        guard let start = seriesStartYear(show) else { return nil }
        if let end = show.endYear, end != start { return "\(start)–\(end)" }
        if show.isContinuing == true { return "\(start)–Present" }
        return "\(start)"
    }

    private func seriesStartYear(_ show: MediaItem) -> Int? {
        if let year = show.year { return year }
        guard let date = show.releaseDate else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        return calendar.component(.year, from: date)
    }

    private var isShow: Bool { item.kind == .show }

    /// Compact technical chips under the metadata — resolution, HDR / Dolby
    /// Vision, video codec, audio. Quality at a glance instead of buried in a
    /// table. Only shown once `MediaInfo` is hydrated.
    @ViewBuilder
    private var mediaBadges: some View {
        let labels = mediaBadgeLabels
        if !labels.isEmpty {
            HStack(spacing: AetherDesign.Spacing.xs) {
                ForEach(labels, id: \.self) { AetherBadge($0) }
            }
            .padding(.top, AetherDesign.Spacing.xxs)
        }
    }

    private var mediaBadgeLabels: [String] {
        guard let info = current.mediaInfo else { return [] }
        var labels: [String] = []
        if let resolution = info.videoResolution { labels.append(resolution) }
        if info.isDolbyVision {
            labels.append("Dolby Vision")
        } else if info.isHDR {
            labels.append("HDR")
        }
        if let codec = info.videoCodec?.uppercased() { labels.append(codec) }
        if let audio = info.audioCodec?.uppercased() {
            if let channels = info.audioChannels {
                labels.append("\(audio) \(channelLabel(channels))")
            } else {
                labels.append(audio)
            }
        }
        // Surface Atmos as its own chip when the codec string advertises it
        // (e.g. "EAC3 (Atmos)"); harmless no-op when the source doesn't report it.
        if let audio = info.audioCodec?.lowercased(), audio.contains("atmos") {
            labels.append("Atmos")
        }
        return labels
    }

    // MARK: - Source badge

    /// The active source as a short uppercase tag (PLEX / JELLYFIN / OFFLINE /
    /// EMBY). Prefers the matching unified source's kind; falls back to the
    /// item's own source id. `nil` when it can't be determined.
    private var sourceLabel: String? {
        if let match = availableSources.first(where: { $0.item.id == activeItem.id }) {
            return match.kind.displayName.uppercased()
        }
        return MediaSourceKind(streaming: activeItem.id.source)?.displayName.uppercased()
    }

    @ViewBuilder
    private var sourceBadge: some View {
        if let label = sourceLabel {
            Text(label)
                .font(.caption2.weight(.semibold))
                .tracking(0.5)
                .padding(.horizontal, AetherDesign.Spacing.xs)
                .padding(.vertical, 3)
                .background(AetherDesign.Palette.surfaceElevated, in: Capsule())
                .foregroundStyle(AetherDesign.Palette.textSecondary)
        }
    }

    // MARK: - Available Sources (manual source override)

    /// Lists every source that has this title. The active one is checked; the
    /// preferred one is tagged. Tapping a different (playable) source re-points
    /// the whole screen at that server. Only rendered when `availableSources`
    /// has more than one entry.
    @ViewBuilder
    private var availableSourcesSection: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            Text("Available Sources")
                .font(AetherDesign.Typography.sectionTitle)
                .foregroundStyle(AetherDesign.Palette.textPrimary)

            VStack(spacing: AetherDesign.Spacing.xs) {
                ForEach(availableSources) { src in
                    sourceRow(src)
                }
            }
        }
    }

    private func sourceRow(_ src: UnifiedSource) -> some View {
        let isActive = src.item.id == activeItem.id
        let isPreferred = src.item.id == item.id
        return Button {
            selectSource(src)
        } label: {
            HStack(spacing: AetherDesign.Spacing.m) {
                Image(systemName: src.kind == .offline ? "arrow.down.circle.fill" : "externaldrive.fill")
                    .font(.title3)
                    .foregroundStyle(AetherDesign.Palette.accent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: AetherDesign.Spacing.xxs) {
                    HStack(spacing: AetherDesign.Spacing.xs) {
                        Text(src.serverName ?? src.kind.displayName)
                            .font(AetherDesign.Typography.cardTitle)
                            .foregroundStyle(AetherDesign.Palette.textPrimary)
                        if isPreferred {
                            AetherBadge("Preferred")
                        }
                    }
                    Text(sourceSubtitle(src))
                        .font(AetherDesign.Typography.caption)
                        .foregroundStyle(AetherDesign.Palette.textTertiary)
                }

                Spacer(minLength: 0)

                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(AetherDesign.Palette.accent)
                }
            }
            .padding(AetherDesign.Spacing.m)
            .background(
                AetherDesign.Materials.card,
                in: RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                    .strokeBorder(
                        isActive ? AetherDesign.Palette.accent : AetherDesign.Palette.separator,
                        lineWidth: isActive ? 2 : 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!src.playable)
        .opacity(src.playable ? 1 : 0.5)
    }

    private func sourceSubtitle(_ src: UnifiedSource) -> String {
        var parts = [src.kind.displayName]
        if let quality = src.quality { parts.append(quality) }
        if !src.playable { parts.append("Unavailable") }
        return parts.joined(separator: " · ")
    }

    /// Switch the screen to a different source. Resets the per-source state
    /// (hydration / playback / resume / children) so `.task(id:)` reloads it for
    /// the chosen server. Clearing `overrideItem` (selecting the preferred
    /// source) returns to the navigated item.
    private func selectSource(_ src: UnifiedSource) {
        guard src.playable, src.item.id != activeItem.id else { return }
        configuredItem = nil
        playbackItem = nil
        children = []
        related = []
        resume = nil
        watchedOverride = nil   // the new source carries its own watched state
        overrideItem = (src.item.id == item.id) ? nil : src.item
    }

    // MARK: - Action row (Resume / Play From Beginning / Play, or unavailable)

    @ViewBuilder
    private var actionRow: some View {
        if current.streamURL != nil {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
                if resume != nil {
                    resumeButtons
                } else {
                    playButton
                }
                #if os(visionOS)
                watchInCinemaButton
                #endif
                if shouldShowDownloadControl {
                    downloadControl
                }
                moreActionsMenu
            }
        } else {
            unavailableState
        }
    }

    /// Secondary actions folded into one unobtrusive menu, so the hero stays
    /// playback-first (replaces the big "Mark as Watched" button). Surfaces
    /// Mark Watched/Unwatched, source switching, and the full technical readout.
    @ViewBuilder
    private var moreActionsMenu: some View {
        Menu {
            if source != nil {
                Button {
                    Task { await toggleWatched() }
                } label: {
                    Label(
                        isWatched ? "Mark as Unwatched" : "Mark as Watched",
                        systemImage: isWatched ? "checkmark.circle.fill" : "checkmark.circle"
                    )
                }
            }

            if availableSources.count > 1 {
                Menu {
                    ForEach(availableSources) { src in
                        Button {
                            selectSource(src)
                        } label: {
                            if src.item.id == activeItem.id {
                                Label(src.serverName ?? src.kind.displayName, systemImage: "checkmark")
                            } else {
                                Text(src.serverName ?? src.kind.displayName)
                            }
                        }
                        .disabled(!src.playable)
                    }
                } label: {
                    Label("Choose Source", systemImage: "rectangle.2.swap")
                }
            }

            if current.mediaInfo != nil {
                Button {
                    presentedSelector = .technicalDetails
                } label: {
                    Label("Technical Details", systemImage: "info.circle")
                }
            }
        } label: {
            moreMenuLabel
        }
    }

    /// Tertiary "More" — deliberately the smallest action so it never competes
    /// with Resume. A compact circular icon on touch / spatial UI; on tvOS a
    /// small labelled chip stays (an icon-only target is hard for the focus
    /// engine to surface).
    @ViewBuilder
    private var moreMenuLabel: some View {
        #if os(tvOS)
        HStack(spacing: AetherDesign.Spacing.xs) {
            Image(systemName: "ellipsis")
            Text("More")
        }
        .font(AetherDesign.Typography.metadata)
        .foregroundStyle(AetherDesign.Palette.textSecondary)
        .padding(.vertical, AetherDesign.Spacing.s)
        .padding(.horizontal, AetherDesign.Spacing.m)
        .background(AetherDesign.Materials.card, in: Capsule())
        .contentShape(Capsule())
        #else
        Image(systemName: "ellipsis")
            .font(AetherDesign.Typography.cardTitle)
            .foregroundStyle(AetherDesign.Palette.textSecondary)
            .frame(width: 46, height: 46)
            .background(AetherDesign.Materials.card, in: Circle())
            .contentShape(Circle())
            .accessibilityLabel("More actions")
        #endif
    }

    /// Displayed watched state — the optimistic override wins over the hydrated
    /// item's server value so the button + badge flip instantly on tap.
    private var isWatched: Bool { watchedOverride ?? current.isWatched }

    private func toggleWatched() async {
        guard let source else { return }
        let next = !isWatched
        watchedOverride = next   // optimistic
        if next {
            await source.markWatched(activeItem.id)
        } else {
            await source.markUnwatched(activeItem.id)
        }
    }

    /// True when a Download surface should appear below the play buttons —
    /// only for Plex / Jellyfin items (the only sources that implement
    /// `downloadURL`), and only once the pipeline has booted.
    private var shouldShowDownloadControl: Bool {
        guard downloadManager != nil, source?.supportsDownloads == true else { return false }
        return true
    }

    /// The state-driven Download surface. Renders as a primary "Download"
    /// button when nothing's recorded; otherwise morphs into a disclosure
    /// row that shows the current status and acts as the primary in-line
    /// action for that state (Pause / Resume / Delete / Retry).
    @ViewBuilder
    private var downloadControl: some View {
        switch downloadStatus {
        case .notDownloaded:
            AetherButton(
                isEnqueuingDownload ? "Starting…" : "Download",
                systemImage: "arrow.down.circle",
                role: .secondary
            ) {
                presentedSelector = .downloadQuality
            }
            .disabled(isEnqueuingDownload)

        case .queued:
            downloadStatusRow(
                value: "Queued",
                actionLabel: "Cancel"
            ) { Task { await cancelDownload() } }

        case let .downloading(fraction):
            downloadStatusRow(
                value: "Downloading · \(percentString(fraction))",
                actionLabel: "Pause"
            ) { Task { await pauseDownload() } }

        case let .paused(fraction):
            downloadStatusRow(
                value: "Paused at \(percentString(fraction))",
                actionLabel: "Resume"
            ) { Task { await resumeDownload() } }

        case let .completed(_, size):
            downloadStatusRow(
                value: "Downloaded · \(formatBytes(size))",
                actionLabel: "Delete"
            ) { Task { await removeDownload() } }

        case let .failed(reason):
            downloadStatusRow(
                value: "Failed · \(reason)",
                actionLabel: "Retry"
            ) { Task { await retryDownload() } }

        case .expired:
            downloadStatusRow(
                value: "Expired",
                actionLabel: "Re-download"
            ) { Task { await retryDownload() } }
        }
    }

    /// One-row layout: status text on the left, single trailing action on
    /// the right. Each transient download state collapses to this so
    /// the row's geometry doesn't shift as progress ticks.
    private func downloadStatusRow(
        value: String,
        actionLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: AetherDesign.Spacing.m) {
            Image(systemName: "arrow.down.circle.fill")
                .font(AetherDesign.Typography.body)
                .foregroundStyle(AetherDesign.Palette.accent)
                .frame(width: 28)
            Text(value)
                .font(AetherDesign.Typography.body)
                .foregroundStyle(AetherDesign.Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: AetherDesign.Spacing.s)
            Button(actionLabel, action: action)
                .buttonStyle(.plain)
                .font(AetherDesign.Typography.metadata)
                .foregroundStyle(AetherDesign.Palette.accent)
        }
        .padding(.vertical, AetherDesign.Spacing.m)
        .padding(.horizontal, AetherDesign.Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                .fill(AetherDesign.Materials.card)
        )
    }

    /// "47%" — keeps the row stable as progress ticks (no decimals,
    /// always two digits at most).
    private func percentString(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// Single "Play" button — shown when there's no saved resume point.
    private var playButton: some View {
        AetherButton(
            isPreparingPlayback ? "Preparing…" : "Play",
            systemImage: "play.fill",
            role: .primary
        ) {
            Task { await presentPlayer(fromStart: true) }
        }
        .disabled(isPreparingPlayback)
    }

    #if os(visionOS)
    /// visionOS-only: enter Cinema Mode — the same title on a cinematic screen
    /// in a dedicated immersive space, driven by the same `PlaybackSession`.
    /// Resumes from the saved point when one exists, else starts from the top,
    /// matching the Play / Resume button above it.
    private var watchInCinemaButton: some View {
        AetherButton(
            "Watch in Cinema",
            systemImage: "visionpro",
            role: .secondary
        ) {
            Task { await watchInCinema() }
        }
        .disabled(isPreparingPlayback)
    }
    #endif

    /// Resume exists: **Resume** (primary, with a resume-from caption) and
    /// **Restart** (secondary) sitting side-by-side, each expanding to
    /// equal width. "Restart" is the Apple-TV-app's name for the same
    /// action — short enough to fit alongside Resume on iPhone without
    /// the row wrapping to two lines. The "Resume from 1:23" caption
    /// stays beneath the row, leading-aligned, so it pairs with Resume
    /// (which is on the left).
    private var resumeButtons: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
            HStack(spacing: AetherDesign.Spacing.s) {
                AetherButton(
                    isPreparingPlayback ? "Preparing…" : "Resume",
                    systemImage: "play.fill",
                    role: .primary
                ) {
                    Task { await presentPlayer(fromStart: false) }
                }
                .frame(maxWidth: .infinity)
                .disabled(isPreparingPlayback)

                AetherButton(
                    "Restart",
                    systemImage: "backward.end.fill",
                    role: .secondary
                ) {
                    Task { await presentPlayer(fromStart: true) }
                }
                .frame(maxWidth: .infinity)
                .disabled(isPreparingPlayback)
            }

            Text("Resume from \(formatPosition(resume?.position ?? .zero))")
                .font(AetherDesign.Typography.caption)
                .foregroundStyle(AetherDesign.Palette.textSecondary)
                .padding(.leading, AetherDesign.Spacing.xs)
        }
    }

    private var unavailableState: some View {
        AetherErrorState(
            glyph: "play.slash",
            title: "Playback unavailable",
            message: "This title isn't streamable yet. If it's a format Plex can't direct-play, transcode support lands in a future update."
        )
        .padding(.top, -AetherDesign.Spacing.xxl)
    }

    // MARK: - Playback options (compact selectors + media info)

    /// Compact Audio / Subtitles / Quality rows. Each row shows the current
    /// selection in muted text and a chevron; tap opens a bottom sheet.
    private var playbackSection: some View {
        AetherSettingsSection("Playback") {
            if !current.audioTracks.isEmpty {
                AetherDisclosureRow(
                    label: "Audio",
                    value: current.selectedAudioTrack?.displayTitle
                ) {
                    presentedSelector = .audio
                }
            }
            if !current.subtitleTracks.isEmpty {
                AetherDisclosureRow(
                    label: "Subtitles",
                    value: current.selectedSubtitleTrack?.displayTitle ?? "Off"
                ) {
                    presentedSelector = .subtitles
                }
            }
            AetherDisclosureRow(
                label: "Quality",
                value: qualityRowValue
            ) {
                presentedSelector = .quality
            }
        }
    }

    /// "Original · Direct Play" / "Convert Automatically" / "8 Mbps 1080p"
    /// — the chosen quality plus a hint at the projected playback mode for
    /// Original (Direct Play if container is AVPlayer-friendly, else
    /// Direct Stream). Other qualities just show their label.
    private var qualityRowValue: String {
        switch current.selectedQuality {
        case .original:
            switch projectedPlaybackMode {
            case .directPlay:   return "Original · Direct Play"
            case .directStream: return "Original · Direct Stream"
            case .transcode:    return "Original"
            }
        default:
            return current.selectedQuality.displayName
        }
    }

    /// The bottom sheet behind the disclosure rows. Half-height on iOS,
    /// full modal on tvOS / visionOS. Takes the `selector` as a
    /// parameter (passed by `.sheet(item:)` at presentation time) so it
    /// always renders the right content — see the comment at the
    /// `.sheet` call site for why reading `presentedSelector` directly
    /// here was the source of the "empty sheet on first open" bug.
    @ViewBuilder
    private func playbackSelectorSheet(for selector: PlaybackSelector) -> some View {
        switch selector {
        case .audio:
            playbackSelectorContent(title: "Audio") {
                audioSelectorList
            }
        case .subtitles:
            playbackSelectorContent(title: "Subtitles") {
                subtitleSelectorList
            }
        case .quality:
            playbackSelectorContent(title: "Quality") {
                qualitySelectorList
            }
        case .downloadQuality:
            playbackSelectorContent(title: "Download Quality") {
                downloadQualitySelectorList
            }
        case .technicalDetails:
            ScrollView {
                VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                    Text("Technical Details")
                        .font(AetherDesign.Typography.sectionTitle)
                        .foregroundStyle(AetherDesign.Palette.textPrimary)
                    mediaSection
                }
                .padding(AetherDesign.Spacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .aetherScreenBackground()
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    /// The sheet body: a calm header + the option list, on the same dark
    /// background the rest of the app uses (the system sheet chrome handles
    /// the "card on top of detail" affordance).
    @ViewBuilder
    private func playbackSelectorContent<Content: View>(
        title: String,
        @ViewBuilder list: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                Text(title)
                    .font(AetherDesign.Typography.sectionTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                    .padding(.horizontal, AetherDesign.Spacing.l)
                    .padding(.top, AetherDesign.Spacing.l)

                VStack(spacing: 0) {
                    list()
                }
                .background(
                    RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                        .fill(AetherDesign.Materials.card)
                )
                .padding(.horizontal, AetherDesign.Spacing.l)
                .padding(.bottom, AetherDesign.Spacing.l)
            }
        }
        .aetherScreenBackground()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var audioSelectorList: some View {
        ForEach(current.audioTracks) { track in
            AetherSelectionRow(
                title: track.displayTitle,
                isSelected: track.id == current.selectedAudioTrackID
            ) {
                configuredItem = current.selectingAudioTrack(track)
                presentedSelector = nil
            }
        }
    }

    private var subtitleSelectorList: some View {
        Group {
            AetherSelectionRow(
                title: "Off",
                isSelected: current.selectedSubtitleTrackID == nil
            ) {
                configuredItem = current.selectingSubtitleTrack(nil)
                presentedSelector = nil
            }
            ForEach(current.subtitleTracks) { track in
                AetherSelectionRow(
                    title: track.displayTitle,
                    isSelected: track.id == current.selectedSubtitleTrackID
                ) {
                    configuredItem = current.selectingSubtitleTrack(track)
                    presentedSelector = nil
                }
            }
        }
    }

    private var qualitySelectorList: some View {
        ForEach(PlaybackQuality.allCases, id: \.self) { quality in
            AetherSelectionRow(
                title: quality.displayName,
                isSelected: quality == current.selectedQuality
            ) {
                configuredItem = current.selectingQuality(quality)
                presentedSelector = nil
            }
        }
    }

    /// Quality picker for the **Download** path. Same options as
    /// `qualitySelectorList`, different action: pick → close sheet →
    /// enqueue download with that quality. No selection state to
    /// "remember" — the user picks once per download, and the choice is
    /// recorded on the `DownloadJob`.
    private var downloadQualitySelectorList: some View {
        ForEach(PlaybackQuality.allCases, id: \.self) { quality in
            AetherSelectionRow(
                title: quality.displayName,
                isSelected: false
            ) {
                presentedSelector = nil
                Task { await startDownload(quality: quality) }
            }
        }
    }

    // MARK: - Download actions

    private func startDownload(quality: PlaybackQuality) async {
        guard let manager = downloadManager, let source else { return }
        isEnqueuingDownload = true
        defer { isEnqueuingDownload = false }
        do {
            _ = try await manager.enqueue(item: current, source: source, quality: quality)
        } catch {
            // Surface failure via the row's next render (DownloadStatus
            // moves to .failed in the store) — no toast / alert chrome
            // for Phase 2.1.
        }
    }

    private func pauseDownload() async {
        guard let manager = downloadManager,
              let job = downloads?.job(for: activeItem.id) else { return }
        await manager.pause(job.id)
    }

    private func resumeDownload() async {
        guard let manager = downloadManager,
              let job = downloads?.job(for: activeItem.id) else { return }
        await manager.resume(job.id)
    }

    private func cancelDownload() async {
        guard let manager = downloadManager,
              let job = downloads?.job(for: activeItem.id) else { return }
        await manager.cancel(job.id)
    }

    private func removeDownload() async {
        guard let manager = downloadManager,
              let job = downloads?.job(for: activeItem.id) else { return }
        await manager.remove(job.id)
    }

    /// Retry path: drop the existing record + start a fresh enqueue at
    /// the same quality. Cleaner than trying to in-place revive a
    /// `.failed` URLSession task (URLSession's resumeData for that task
    /// is gone by then).
    private func retryDownload() async {
        guard let manager = downloadManager,
              let source,
              let job = downloads?.job(for: activeItem.id) else { return }
        let quality = job.quality
        await manager.remove(job.id)
        do {
            _ = try await manager.enqueue(item: current, source: source, quality: quality)
        } catch {
            // Same swallow as `startDownload` — store status will reflect.
        }
    }

    /// Source media info + projected playback mode. The codecs / bitrate /
    /// resolution come from Plex metadata as the file is on disk; the
    /// "Playback" line is a best-effort guess based on container + quality.
    /// The server's actual decision is taken when Play is pressed.
    @ViewBuilder
    private var mediaSection: some View {
        let info = current.mediaInfo
        AetherSettingsSection("Media Information") {
            if let video = videoLine(info) {
                AetherSettingsRow(label: "Video", value: video)
            }
            if let audio = audioLine(info) {
                AetherSettingsRow(label: "Audio", value: audio)
            }
            if let bitrate = info?.bitrateKbps {
                AetherSettingsRow(label: "Bitrate", value: formatBitrate(bitrate))
            }
            if let hdrBadge = hdrBadge(info) {
                AetherSettingsRow(label: "HDR", value: hdrBadge)
            }
            AetherSettingsRow(label: "Playback", status: playbackModeStatus)
            if let source {
                AetherSettingsRow(label: "Source", value: source.displayName)
            }
        }
    }

    private func videoLine(_ info: MediaInfo?) -> String? {
        guard let info else { return nil }
        let codec = info.videoCodec?.uppercased()
        let resolution = info.videoResolution
        switch (codec, resolution) {
        case let (codec?, resolution?): return "\(codec) \(resolution)"
        case let (codec?, nil):         return codec
        case let (nil, resolution?):    return resolution
        case (nil, nil):                return nil
        }
    }

    private func audioLine(_ info: MediaInfo?) -> String? {
        guard let info else { return nil }
        let codec = info.audioCodec?.uppercased()
        let channels = info.audioChannels.map { channelLabel($0) }
        switch (codec, channels) {
        case let (codec?, channels?): return "\(codec) \(channels)"
        case let (codec?, nil):       return codec
        case let (nil, channels?):    return channels
        case (nil, nil):              return nil
        }
    }

    /// Plex's channel count → loudspeaker layout label: 2 → "2.0", 6 → "5.1",
    /// 8 → "7.1". Anything we don't recognise falls back to "N ch".
    private func channelLabel(_ channels: Int) -> String {
        switch channels {
        case 1: return "Mono"
        case 2: return "2.0"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(channels) ch"
        }
    }

    private func hdrBadge(_ info: MediaInfo?) -> String? {
        guard let info else { return nil }
        if info.isDolbyVision { return "Dolby Vision" }
        if info.isHDR { return "HDR" }
        return nil
    }

    private func formatBitrate(_ kbps: Int) -> String {
        if kbps >= 1000 {
            let mbps = Double(kbps) / 1000.0
            return String(format: "%.1f Mbps", mbps)
        }
        return "\(kbps) kbps"
    }

    /// Best-effort projected playback mode for the Media line, computed from
    /// container + quality choice. The server's actual decision is taken when
    /// Play is pressed; this is just a hint so the user knows what'll happen.
    private var playbackModeStatus: AetherStatus {
        let mode = projectedPlaybackMode
        switch mode {
        case .directPlay:   return .positive(mode.displayName)
        case .directStream: return .positive(mode.displayName)
        case .transcode:    return .muted(mode.displayName)
        }
    }

    private var projectedPlaybackMode: PlaybackDecisionMode {
        let container = current.mediaInfo?.container?.lowercased()
        let directPlayContainers: Set<String> = ["mp4", "m4v", "mov"]
        switch current.selectedQuality {
        case .original:
            if let container, directPlayContainers.contains(container) {
                return .directPlay
            }
            return .directStream
        case .convertAutomatically:
            return .directStream
        case .bitrate20Mbps1080p, .bitrate12Mbps1080p, .bitrate8Mbps1080p,
             .bitrate4Mbps720p, .bitrate2Mbps720p, .bitrate720kbps:
            return .transcode
        }
    }

    private func hydrateForPlayback() async {
        guard !activeItem.kind.isContainer, let source else { return }
        if let hydrated = try? await source.item(for: activeItem.id) {
            configuredItem = applyingPreferences(to: hydrated)
        }
    }

    /// Seeds the user's app-wide playback defaults onto a freshly hydrated
    /// item. Each preference is applied only when it points at a track that
    /// actually exists on the title — a Czech-audio default doesn't force
    /// English-only content into silence — and only when set; `nil` means
    /// "follow the source default" and falls through to whatever the source
    /// (Plex / Jellyfin) already picked. The user's per-title picker tap
    /// later still wins for that session.
    private func applyingPreferences(to hydrated: MediaItem) -> MediaItem {
        guard let prefs = playbackPreferences else { return hydrated }
        var result = hydrated

        // Audio: match by language code (case-insensitive). Only override
        // when the title has a track in the preferred language.
        if let preferred = prefs.defaultAudioLanguage?.lowercased(),
           let track = result.audioTracks.first(where: {
               $0.languageCode?.lowercased() == preferred
           }) {
            result = result.selectingAudioTrack(track)
        }

        // Subtitles: "off" disables subs entirely; nil leaves whatever the
        // source picked; a language code selects the first matching track.
        if let preferred = prefs.defaultSubtitleLanguage {
            if preferred == "off" {
                result = result.selectingSubtitleTrack(nil)
            } else if let track = result.subtitleTracks.first(where: {
                $0.languageCode?.lowercased() == preferred.lowercased()
            }) {
                result = result.selectingSubtitleTrack(track)
            }
        }

        // Quality: always applied. The MediaItem default is `.original`,
        // but most users want the picker to open on whatever they chose
        // last as their everywhere-default.
        result = result.selectingQuality(prefs.defaultQuality)

        return result
    }

    // MARK: - Player dismiss

    private func presentPlayer(fromStart: Bool) async {
        #if os(visionOS)
        // Auto-Enter Cinema (Settings): start playback straight in the immersive
        // theater instead of the windowed player. Routed before the guard so
        // watchInCinema()'s own isPreparingPlayback guard takes effect.
        if CinemaPreferencesStore().autoEnterCinema {
            await watchInCinema(fromStart: fromStart)
            return
        }
        #endif
        guard !isPreparingPlayback else { return }
        isPreparingPlayback = true
        defer { isPreparingPlayback = false }

        // `current` is already hydrated (on appear) and carries the user's
        // audio + subtitle + quality choices, so the player launches exactly
        // what the Detail screen showed. Fall back to a fresh hydrate if it
        // somehow hasn't resolved yet.
        if configuredItem == nil, let source, let hydrated = try? await source.item(for: activeItem.id) {
            configuredItem = hydrated
        }
        playbackItem = current

        // `0` forces a restart; `nil` lets the session resume from the
        // persisted point.
        playbackStartAt = fromStart ? 0 : nil
        launchingInCinema = false   // windowed playback stays embedded

        withAnimation(reduceMotion ? nil : AetherDesign.Motion.hero) {
            isPlayerPresented = true
        }
    }

    private func dismissPlayer() {
        withAnimation(reduceMotion ? nil : AetherDesign.Motion.hero) {
            isPlayerPresented = false
        }
        playbackItem = nil
        #if os(visionOS)
        // No-op unless this was a cinema session; tears down the Dark Theater.
        cinema.end()
        #endif
        Task { resume = await resumeStore.point(for: activeItem.id) }
    }

    #if os(visionOS)
    /// Enter Cinema Mode: present the native player (same `PlayerView` /
    /// `AVPlayerViewController` as windowed playback) **and** ask `CinemaManager`
    /// to open the Dark Theater. The system then docks the fullscreen player
    /// into the immersive space — native controls, native sizing. `nil` startAt
    /// resumes from the saved point, mirroring the Resume button.
    private func watchInCinema(fromStart: Bool = false) async {
        guard !isPreparingPlayback else { return }
        isPreparingPlayback = true
        defer { isPreparingPlayback = false }

        if configuredItem == nil, let source, let hydrated = try? await source.item(for: activeItem.id) {
            configuredItem = hydrated
        }
        playbackItem = current
        playbackStartAt = fromStart ? 0 : (resume != nil ? nil : 0)
        launchingInCinema = true   // auto-expand so it docks into the theater
        // Open with the resolved entry size + seat — the Settings defaults, or
        // the last-used config when "Remember Last Setup" is on (changeable live
        // in-cinema). Read transiently from UserDefaults — Detail doesn't carry
        // the store, and the value is the source of truth.
        let cinemaPrefs = CinemaPreferencesStore()
        cinema.present(current, source: source, startAt: playbackStartAt,
                       preset: cinemaPrefs.entryScreenPreset, seat: cinemaPrefs.entrySeat)
        withAnimation(reduceMotion ? nil : AetherDesign.Motion.hero) {
            isPlayerPresented = true
        }
    }
    #endif

    // MARK: - Formatting helpers

    private func kindLabel(_ kind: MediaItem.Kind) -> String {
        switch kind {
        case .movie: return "Movie"
        case .episode: return "Episode"
        case .show: return "Series"
        case .season: return "Season"
        }
    }

    private func formatRuntime(_ duration: Duration) -> String {
        let total = Int(durationSeconds(duration))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private func formatPosition(_ duration: Duration) -> String {
        let total = Int(durationSeconds(duration))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func durationSeconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

private extension View {
    /// Apply `.focusSection()` on tvOS so the focus engine can move into and
    /// **out of** this region (e.g. Up from the seasons rail back to the tab
    /// bar). No-op elsewhere — the API is tvOS-only.
    @ViewBuilder
    func aetherDetailFocusSection() -> some View {
        #if os(tvOS)
        self.focusSection()
        #else
        self
        #endif
    }
}
