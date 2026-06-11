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
    @State private var favoriteOverride: Bool?
    @State private var isPlayerPresented = false
    /// Set when a local file needs the VLCKit engine (mkv etc.) instead of AVKit.
    @State private var vlcPlayback: VLCPlayback?
    @State private var playbackItem: MediaItem?
    /// Where the presented player should begin. `nil` resumes from the saved
    /// point ("Resume"); `0` forces a restart ("Play From Beginning").
    @State private var playbackStartAt: Double?
    @State private var isPreparingPlayback = false
    /// visionOS: the current player presentation was launched via "Watch in
    /// Cinema" → auto-expand so it docks into the Dark Theater without a tap.
    @State private var launchingInCinema = false
    #if os(visionOS)
    /// visionOS: drives the "Continue or Start Over" prompt before entering
    /// Cinema Mode when a resume point exists.
    @State private var showCinemaResumePrompt = false
    #endif
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
    /// Resume points for the currently-listed episodes, so each row can show how
    /// far in you are (#260). Keyed by episode id; filled when episodes load.
    @State private var episodeResume: [MediaID: ResumePoint] = [:]
    /// tvOS: which season card has focus, so the Show page previews it while
    /// browsing (#266 — Focus = Preview, Select = Open).
    @FocusState private var focusedSeasonID: MediaID?
    /// Last-focused season, kept so the preview stays put when focus leaves the
    /// rail (defaults to the first season).
    @State private var previewSeasonID: MediaID?
    /// tvOS: which episode still has focus — the rail previews it below
    /// (synopsis, runtime, air date, resume), same Focus = Preview model (#267).
    @FocusState private var focusedEpisodeID: MediaID?
    /// Last-focused episode, kept so the preview stays put when focus leaves.
    @State private var previewEpisodeID: MediaID?
    /// Season pages rarely carry their own cast — the parent show's cast,
    /// fetched as a fallback so Cast & Crew isn't missing on a season (#267).
    @State private var fallbackCast: [CastMember] = []
    /// The title's clearLogo, once loaded — the hero swaps its text title for
    /// this wordmark art. Stays nil (text title) for the majority of titles
    /// whose source has no logo (#273).
    @State private var heroLogo: AetherPlatformImage?
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
    // Set when the local metadata editor closes, to re-point the screen at the
    // edited item so its title / poster / overview repaint (#211). Seeded nil so
    // the re-hydrate task below is a no-op on first appear (no double fetch).
    @State private var localEditToken: UUID?
    /// True while a Download is being prepared (quality picker → enqueue) so
    /// the button can read "Starting…" and disable.
    @State private var isEnqueuingDownload = false
    /// Technical Details starts tucked — rich info without cluttering the page.
    @State private var technicalDetailsExpanded = false
    /// First-use discoverability for the bare compact icon row: captions show
    /// beneath the icons until the user taps one, then never again (persisted).
    @AppStorage("aether.detail.iconHintSeen") private var iconHintSeen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Drives the backdrop layout: compact (iPhone) → full-width 16:9; regular
    /// (iPad / tvOS / visionOS) → edge-to-edge fill at a fixed height.
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.dismiss) private var dismiss
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
        #if !os(tvOS)
        case editMetadata
        #endif
        var id: String {
            switch self {
            case .audio: return "audio"
            case .subtitles: return "subtitles"
            case .quality: return "quality"
            case .downloadQuality: return "downloadQuality"
            case .technicalDetails: return "technicalDetails"
            #if !os(tvOS)
            case .editMetadata: return "editMetadata"
            #endif
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
            if item.kind == .season {
                // Season page: its children ARE its episodes — Next Up within
                // the season, and the parent show's cast as a fallback (#267).
                await computeNextUp()
                await loadFallbackCastIfNeeded()
            }
            related = await source?.related(to: activeItem.id) ?? []
        }
        // Re-point the screen after the local metadata editor closes (#211): the
        // item id is unchanged, so the main task won't re-run. Feeding the
        // refreshed item into `overrideItem` (the same channel the source switch
        // uses) repaints the hero, which reads `activeItem`. If the edit changed
        // the kind (movie↔episode) the item now lives under a different library
        // grouping, so pop back rather than render a contradictory screen.
        .task(id: localEditToken) {
            guard localEditToken != nil,
                  activeItem.id.source == .local,
                  let source,
                  let refreshed = try? await source.item(for: activeItem.id) else { return }
            if refreshed.kind != activeItem.kind {
                dismiss()
            } else {
                overrideItem = refreshed
                configuredItem = applyingPreferences(to: refreshed)
            }
        }
        // clearLogo for the hero — keyed on the minted URL so it re-fires when
        // hydration fills `configuredItem` (Plex logos arrive on the detail
        // endpoint, not the library list) and when the user switches source.
        .task(id: current.logoURL()) {
            guard item.kind != .episode, let url = current.logoURL() else {
                heroLogo = nil
                return
            }
            heroLogo = await AetherImageCache.shared.image(for: url, maxPixel: ArtworkTier.logo.maxPixel)
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
        .fullScreenCover(item: $vlcPlayback) { playback in
            VLCPlayerView(url: playback.url) { vlcPlayback = nil }
                .ignoresSafeArea()
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
                        url: activeItem.backdropURL(.backdrop) ?? activeItem.posterURL(.detail),
                        height: hSizeClass == .regular ? backdropMaxHeight : nil
                    )

                    VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
                        heroTitleBlock
                        metadataRow
                        genresRow
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
                        AetherExpandableText(summary)
                            .padding(.horizontal, AetherDesign.Spacing.l)
                            .frame(maxWidth: 720, alignment: .leading)
                    }

                    if !item.kind.isContainer, current.mediaInfo != nil {
                        technicalDetailsSection
                            .padding(.horizontal, AetherDesign.Spacing.l)
                            .frame(maxWidth: 720, alignment: .leading)
                    }

                    // Only meaningful when the title exists on more than one source.
                    if availableSources.count > 1 {
                        availableSourcesSection
                            .padding(.horizontal, AetherDesign.Spacing.l)
                            .frame(maxWidth: 720, alignment: .leading)
                    }

                    // Season detail (browsed into directly): Next Up + episode list.
                    if item.kind.isContainer {
                        if item.kind == .season {
                            nextUpCard
                                .padding(.horizontal, AetherDesign.Spacing.l)
                        }
                        childrenSection
                            .padding(.horizontal, AetherDesign.Spacing.l)
                    }

                    // Cast & Crew sits below the primary actions / overview /
                    // sources (#247) — valuable, but not competing with them.
                    // Seasons fall back to the parent show's cast (#267).
                    if item.kind != .show {
                        castSection
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
                url: activeItem.backdropURL(heroBackdropTier) ?? activeItem.posterURL(.detail),
                maxPixel: heroBackdropTier.maxPixel
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .overlay { wideScrim }
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                    // Primary content stays in the readable left column…
                    VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                        heroTitleBlock
                        metadataRow
                        genresRow

                        if !item.kind.isContainer {
                            actionRow
                        }

                        if let summary = activeItem.summary {
                            if item.kind.isContainer {
                                Text(summary)
                                    .font(AetherDesign.Typography.body)
                                    .foregroundStyle(AetherDesign.Palette.textSecondary)
                                    .lineLimit(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                synopsis(summary)
                            }
                        }

                        // Season page: "continue this season" one click away —
                        // and, as a full-width focus section, the Up target for
                        // the episode rail below (#267).
                        if item.kind == .season {
                            nextUpCard
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .aetherDetailFocusSection()
                        }

                        if !item.kind.isContainer, current.streamURL != nil {
                            playbackSection
                        }
                        if !item.kind.isContainer, current.mediaInfo != nil {
                            technicalDetailsSection
                        }
                        if availableSources.count > 1 {
                            availableSourcesSection
                        }
                    }
                    .frame(maxWidth: wideColumnWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AetherDesign.Spacing.xl)

                    // Seasons / Episodes rail breaks out of the left column on
                    // tvOS so it uses the full screen width (#266) — the text
                    // stays readable on the left, the rail spans the screen.
                    if item.kind.isContainer {
                        childrenSection
                            #if os(tvOS)
                            .padding(.leading, AetherDesign.Spacing.xl)
                            #else
                            .frame(maxWidth: wideColumnWidth, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, AetherDesign.Spacing.xl)
                            #endif
                    }

                    // …but Cast & Crew sits last (#247) and, on tvOS, breaks out
                    // of the column so the rail uses the full screen width.
                    // Seasons show it too — their own cast when the source has
                    // one, else the parent show's (#267).
                    if item.kind != .show {
                        castSection
                            #if os(tvOS)
                            .padding(.leading, AetherDesign.Spacing.xl)
                            #else
                            .frame(maxWidth: wideColumnWidth, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, AetherDesign.Spacing.xl)
                            #endif
                    }
                }
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
                // Cinematic surfaces (tvOS / visionOS / landscape) keep the
                // full-bleed hero with the actions embedded over the backdrop.
                // iPhone portrait gets an efficient banner: a shorter backdrop
                // band with the title / metadata / actions stacked *below* it,
                // so the first decision ("play this?") is reachable without
                // scrolling and the backdrop stops behaving like a poster.
                if isCinematicHero(size) {
                    movieHero(size)
                } else {
                    movieBanner(size)
                }

                // Below the hero — same order on every platform: what-it's-about,
                // then the richer sections, then discovery, with playback config
                // kept last (most users never touch it). §5: description follows
                // the actions, never precedes them.
                movieBelowHero
                    .padding(.horizontal, AetherDesign.Spacing.l)
            }
            .padding(.bottom, AetherDesign.Spacing.xxl)
        }
    }

    /// Below-hero section stack, shared by the cinematic and banner movie
    /// layouts. Description → Available Sources → Technical Details →
    /// More Like This → Playback settings (config dead last).
    /// Synopsis treatment: a 3-line teaser on tvOS (users browse visually from
    /// across the room and the expand control is another focus stop), expandable
    /// More/Less on touch + spatial.
    @ViewBuilder
    private func synopsis(_ summary: String) -> some View {
        #if os(tvOS)
        Text(summary)
            .font(AetherDesign.Typography.body)
            .foregroundStyle(AetherDesign.Palette.textSecondary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
        #else
        AetherExpandableText(summary)
        #endif
    }

    @ViewBuilder
    private var movieBelowHero: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
            if let summary = activeItem.summary {
                synopsis(summary)
                    .frame(maxWidth: 720, alignment: .leading)
            }
            if availableSources.count > 1 {
                availableSourcesSection
                    .frame(maxWidth: 720, alignment: .leading)
                    .aetherDetailFocusSection()
            }
            if current.mediaInfo != nil {
                technicalDetailsSection
                    .frame(maxWidth: 720, alignment: .leading)
                    .aetherDetailFocusSection()
            }
            relatedRail
            if current.streamURL != nil {
                playbackSection
                    .frame(maxWidth: 720, alignment: .leading)
            }
            // Cast & Crew last — below Related (#247).
            castSection
        }
    }

    /// True when the hero should be the full-bleed cinematic stage (actions
    /// embedded over the backdrop): tvOS / visionOS always, and any landscape
    /// surface. iPhone *portrait* (compact width) gets the banner instead;
    /// iPad portrait stays cinematic (it has the room and read well already).
    private func isCinematicHero(_ size: CGSize) -> Bool {
        #if os(tvOS) || os(visionOS)
        return true
        #else
        if size.width > size.height { return true }   // landscape → cinematic
        return hSizeClass != .compact                 // portrait: iPhone → banner, iPad → cinematic
        #endif
    }

    /// iPhone-portrait movie layout: a shorter backdrop *banner* with the title,
    /// metadata, genres, badges and the action row stacked beneath it (not
    /// overlaid). Prioritises information density over cinematic scale on a
    /// small display — Title · Metadata · Genres · Resume · Restart land above
    /// the fold.
    private func movieBanner(_ size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            CachedAsyncImage(
                url: activeItem.backdropURL(.backdrop) ?? activeItem.posterURL(.detail),
                maxPixel: ArtworkTier.backdrop.maxPixel
            )
                .frame(width: size.width, height: compactHeroHeight(size))
                .clipped()
                .overlay(alignment: .bottom) { bannerScrim }

            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
                heroTitleBlock
                metadataRow
                genresRow
            }
            .padding(.horizontal, AetherDesign.Spacing.l)

            if !item.kind.isContainer {
                actionRow
                    .padding(.horizontal, AetherDesign.Spacing.l)
            }
        }
    }

    /// A short bottom fade on the banner backdrop so the title below it reads
    /// against the image edge without the heavy full-hero scrim.
    private var bannerScrim: some View {
        LinearGradient(
            colors: [.clear, AetherDesign.Palette.background.opacity(0.85)],
            startPoint: .center,
            endPoint: .bottom
        )
    }

    /// Banner height for iPhone portrait — a 16:9-ish band capped at roughly a
    /// third of the viewport, so it reads as a backdrop treatment rather than a
    /// full-screen poster (the §7 complaint).
    private func compactHeroHeight(_ size: CGSize) -> CGFloat {
        min(size.width * 9.0 / 16.0, size.height * 0.34)
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
                heroTitleBlock

                HStack(spacing: AetherDesign.Spacing.s) {
                    Text(metadataParts.joined(separator: " • "))
                        .font(AetherDesign.Typography.metadata)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                    sourceBadge
                    Spacer(minLength: 0)
                }

                genresRow

                mediaBadges

                // Description moved out of the hero (§5): it now follows the
                // actions in `movieBelowHero`, so the play decision comes first.
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
        // Trimmed from the earlier 0.80–0.82: with the description no longer
        // embedded the hero needs less height, reclaiming vertical space for
        // the content below while staying cinematic on the big surfaces.
        #if os(tvOS)
        return size.height * 0.74
        #else
        // Landscape stays cinematic but a touch shorter; iPad portrait (the
        // only portrait surface still routed here) gets a calmer half-screen.
        return size.width > size.height ? size.height * 0.72 : size.height * 0.52
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
                relatedHeader

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

    /// The "More Like This" title — plain text. Up-escape from the rail is handled
    /// by making the REAL section above it a focus section (the seasons rail on a
    /// series page; Available Sources / Technical Details on a movie page), rather
    /// than the earlier no-op header button (#266 — "do it properly").
    private var relatedHeader: some View {
        Text("More Like This")
            .font(AetherDesign.Typography.sectionTitle)
            .foregroundStyle(AetherDesign.Palette.textPrimary)
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

    /// Season poster cards run a touch wider on the 10-foot UI so the named
    /// "S2 · Asylum" labels have room to breathe over two lines (#263).
    private var seasonCardWidth: CGFloat {
        #if os(tvOS)
        return 180
        #else
        return 140
        #endif
    }

    private var seasonsRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: AetherDesign.Spacing.m) {
                ForEach(children) { season in
                    NavigationLink(value: season) {
                        AetherCard.poster(
                            title: DetailFormatting.seasonLabel(season),
                            posterURL: season.posterURL,
                            isWatched: (season.unwatchedEpisodeCount ?? 1) == 0,
                            // Named seasons ("S2 · Asylum") need a second line so
                            // they don't clip to "Seaso…" on the 10-foot UI (#263).
                            titleLineLimit: 2
                        )
                        .frame(width: seasonCardWidth)
                        .seasonCardFocus()
                    }
                    .buttonStyle(.plain)
                    .focused($focusedSeasonID, equals: season.id)
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

    /// A titled rail of season poster cards on the show page — each pushes a
    /// dedicated Season Detail (#245). Used for multi-season shows; single-season
    /// shows render their episodes inline instead.
    private var seasonsSection: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            Text("Seasons")
                .font(AetherDesign.Typography.sectionTitle)
                .foregroundStyle(AetherDesign.Palette.textPrimary)
            seasonsRail
            #if os(tvOS)
            // Focus = Preview: a lightweight read-out of the season currently
            // under focus (Select still opens the dedicated Season Detail) (#266).
            seasonPreview
            #endif
        }
        #if os(tvOS)
        .onChange(of: focusedSeasonID) { _, id in
            if let id { previewSeasonID = id }
        }
        #endif
    }

    #if os(tvOS)
    /// The season the preview describes — the last-focused one, else the first.
    private var previewSeason: MediaItem? {
        children.first { $0.id == previewSeasonID } ?? children.first
    }

    /// Lightweight preview of the focused season on the Show page: name, year /
    /// episode count / progress, and a short overview — immediate context while
    /// browsing without leaving for the Season Detail (#266).
    @ViewBuilder
    private var seasonPreview: some View {
        if let season = previewSeason {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
                Text(DetailFormatting.seasonLabel(season))
                    .font(AetherDesign.Typography.cardTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                if let meta = seasonPreviewMeta(season) {
                    Text(meta)
                        .font(AetherDesign.Typography.metadata)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                }
                if let summary = season.summary, !summary.isEmpty {
                    Text(summary)
                        .font(AetherDesign.Typography.body)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .animation(AetherDesign.Motion.hero, value: previewSeasonID)
        }
    }

    /// "2017 • 11 Episodes • 7/11 watched" — year, episode count, watch progress.
    private func seasonPreviewMeta(_ season: MediaItem) -> String? {
        var parts: [String] = []
        if let year = season.year { parts.append(String(year)) }
        if let count = season.episodeCount, count > 0 {
            parts.append("\(count) Episode\(count == 1 ? "" : "s")")
            if let unwatched = season.unwatchedEpisodeCount {
                if unwatched == 0 {
                    parts.append("Watched")
                } else if count - unwatched > 0 {
                    parts.append("\(count - unwatched)/\(count) watched")
                }
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }
    #endif

    @ViewBuilder
    private var episodesList: some View {
        #if os(tvOS)
        episodeRail(children)
        #else
        LazyVStack(spacing: AetherDesign.Spacing.m) {
            ForEach(children) { episode in
                NavigationLink(value: episode) {
                    episodeRow(episode)
                }
                .buttonStyle(.plain)
            }
        }
        #endif
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
                            .foregroundStyle(Color.black, AetherDesign.Palette.accentGold)
                            .font(.system(size: 18, weight: .bold))
                            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                            .padding(AetherDesign.Spacing.xs)
                    }
                }
                // In-progress: a resume bar across the bottom of the still (#260).
                .overlay(alignment: .bottom) { episodeProgressBar(episode) }

            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xxs) {
                Text(episode.title)
                    .font(AetherDesign.Typography.cardTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                    .lineLimit(2)
                if let resume = episodeResume[episode.id], !episode.isWatched {
                    Text("Resume \(DetailFormatting.position(resume.position))")
                        .font(AetherDesign.Typography.caption)
                        .foregroundStyle(AetherDesign.Palette.accent)
                } else if let runtime = episode.runtime {
                    Text(DetailFormatting.runtime(runtime))
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

    /// A thin resume bar across the bottom of an episode still when it's
    /// partially watched (#260) — so in-progress episodes are obvious in a list.
    @ViewBuilder
    private func episodeProgressBar(_ episode: MediaItem) -> some View {
        if let resume = episodeResume[episode.id], !episode.isWatched, let runtime = episode.runtime {
            let total = DetailFormatting.seconds(runtime)
            let fraction = total > 0 ? min(1, max(0, DetailFormatting.seconds(resume.position) / total)) : 0
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.25))
                    Capsule().fill(AetherDesign.Palette.accent)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 4)
            .padding(.horizontal, AetherDesign.Spacing.xs)
            .padding(.bottom, AetherDesign.Spacing.xs)
        }
    }

    #if os(tvOS)
    // MARK: - tvOS episode rail (Detail Phase 2)

    /// Wide 16:9 still cards, like the Infuse "Season N" rail.
    private var episodeStillWidth: CGFloat { 320 }

    /// "2. Ladies Room" — ordinal-prefixed episode title for the still rail.
    private func episodeOrdinalTitle(_ episode: MediaItem) -> String {
        if let number = episode.episodeNumber { return "\(number). \(episode.title)" }
        return episode.title
    }

    /// Resume time when in-progress, else air date, else runtime.
    private func episodeCaption(_ episode: MediaItem) -> String {
        if let resume = episodeResume[episode.id], !episode.isWatched {
            return "Resume \(DetailFormatting.position(resume.position))"
        }
        if let date = episode.releaseDate { return DetailFormatting.airDate(date) }
        if let runtime = episode.runtime { return DetailFormatting.runtime(runtime) }
        return ""
    }

    /// tvOS episode browsing: a horizontal rail of 16:9 stills (ordinal title +
    /// resume/date caption), mirroring the Infuse "Season N" rail instead of a
    /// tall vertical list. Each still keeps its watched marker + in-progress bar.
    private func episodeRail(_ episodes: [MediaItem]) -> some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: AetherDesign.Spacing.l) {
                    ForEach(episodes) { episode in
                        NavigationLink(value: episode) { episodeStillCard(episode) }
                            .buttonStyle(.plain)
                            .focused($focusedEpisodeID, equals: episode.id)
                    }
                }
                .padding(.vertical, AetherDesign.Spacing.xs)
            }
            .aetherDetailFocusSection()

            // Focus = Preview: browsing the rail reads out the focused episode
            // below it (synopsis, runtime, air date, resume) — the stills alone
            // often look identical when a source has no per-episode art (#267).
            episodePreview(episodes)
        }
        .onChange(of: focusedEpisodeID) { _, id in
            if let id { previewEpisodeID = id }
        }
    }

    /// Lightweight preview of the focused episode under the rail. Falls back to
    /// the first episode so the space never sits empty.
    @ViewBuilder
    private func episodePreview(_ episodes: [MediaItem]) -> some View {
        if let episode = episodes.first(where: { $0.id == previewEpisodeID }) ?? episodes.first {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
                Text(episodeOrdinalTitle(episode))
                    .font(AetherDesign.Typography.cardTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                if let meta = episodePreviewMeta(episode) {
                    Text(meta)
                        .font(AetherDesign.Typography.metadata)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                }
                if let summary = episode.summary, !summary.isEmpty {
                    Text(summary)
                        .font(AetherDesign.Typography.body)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .animation(AetherDesign.Motion.hero, value: previewEpisodeID)
        }
    }

    /// "50m • Sep 26, 2017 • Resume 12:30" / "… • Watched" — the preview's
    /// glanceable second line.
    private func episodePreviewMeta(_ episode: MediaItem) -> String? {
        var parts: [String] = []
        if let runtime = episode.runtime { parts.append(DetailFormatting.runtime(runtime)) }
        if let date = episode.releaseDate { parts.append(DetailFormatting.airDate(date)) }
        if let resume = episodeResume[episode.id], !episode.isWatched {
            parts.append("Resume \(DetailFormatting.position(resume.position))")
        } else if episode.isWatched {
            parts.append("Watched")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    /// Built on `AetherCard` so the still wears the **same** watched marker as
    /// posters — the bold gold corner ribbon, not a small checkmark — and the
    /// same prominent progress bar for in-progress episodes (#266 feedback).
    private func episodeStillCard(_ episode: MediaItem) -> some View {
        AetherCard(
            title: episodeOrdinalTitle(episode),
            subtitle: episodeCaption(episode),
            posterURL: episode.backdropURL(.still) ?? episode.posterURL(.thumbnail),
            aspectRatio: 16.0 / 9.0,
            progress: episodeProgressFraction(episode),
            isWatched: episode.isWatched,
            titleLineLimit: 1
        )
        .frame(width: episodeStillWidth)
    }

    /// Watched fraction for an in-progress (not-yet-watched) episode, else `nil`
    /// so `AetherCard` shows no progress bar.
    private func episodeProgressFraction(_ episode: MediaItem) -> Double? {
        guard let resume = episodeResume[episode.id], !episode.isWatched,
              let runtime = episode.runtime else { return nil }
        let total = DetailFormatting.seconds(runtime)
        guard total > 0 else { return nil }
        return min(1, max(0, DetailFormatting.seconds(resume.position) / total))
    }
    #endif

    private func loadChildrenIfNeeded() async {
        guard activeItem.kind.isContainer, let source, children.isEmpty else { return }
        isLoadingChildren = true
        defer { isLoadingChildren = false }
        do {
            children = try await source.children(of: activeItem.id)
            // A navigated season's children are episodes — load their resume
            // points so the rows show in-progress state (#260).
            if children.contains(where: { $0.kind == .episode }) {
                await loadEpisodeResumes(children)
            }
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
                // Full-width focus section so Up from ANY season card lands on
                // Next Up — section-to-section focus uses the section frames, not
                // the card geometry, so it works from Season 1 through Season N
                // (#266 feedback). Pairs with the seasons rail's own focus section.
                nextUpCard
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .aetherDetailFocusSection()
                if children.count > 1 {
                    // Multi-season: a rail of season poster cards that push a
                    // dedicated Season Detail (#245), instead of an inline
                    // selector + flat episode list.
                    seasonsSection
                } else {
                    // Single-season: skip the pointless drill and show the lone
                    // season's episodes inline.
                    seasonEpisodesSection
                }
                if let summary = activeItem.summary {
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
                        Text(DetailFormatting.episodeLabel(episode))
                            .font(AetherDesign.Typography.cardTitle)
                            .foregroundStyle(AetherDesign.Palette.textPrimary)
                            .lineLimit(2)
                        if let resume = nextUpResume {
                            Text("Resume from \(DetailFormatting.position(resume.position))")
                                .font(AetherDesign.Typography.caption)
                                .foregroundStyle(AetherDesign.Palette.textSecondary)
                        } else if let runtime = episode.runtime {
                            Text(DetailFormatting.runtime(runtime))
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
                        Text(DetailFormatting.seasonLabel(season))
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

    @ViewBuilder
    private var seasonEpisodesSection: some View {
        if isLoadingEpisodes {
            AetherLoadingState(.inline)
        } else if !seasonEpisodes.isEmpty {
            #if os(tvOS)
            episodeRail(seasonEpisodes)
            #else
            LazyVStack(spacing: AetherDesign.Spacing.m) {
                ForEach(seasonEpisodes) { episode in
                    NavigationLink(value: episode) {
                        episodeRow(episode)
                    }
                    .buttonStyle(.plain)
                }
            }
            #endif
        }
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
        if let deck { await loadSeasonEpisodes(deck) }
        await computeNextUp()
    }

    /// Every episode of the show, across all seasons. `children` are seasons for
    /// Plex/Jellyfin (fetch each one's episodes) or already episodes for a flat
    /// source (Local) — handle both.
    private func allShowEpisodes() async -> [MediaItem] {
        guard let source else { return [] }
        if children.contains(where: { $0.kind == .season }) {
            var episodes: [MediaItem] = []
            for season in children {
                episodes += (try? await source.children(of: season.id)) ?? []
            }
            return episodes
        }
        return children   // already episodes (flat source)
    }

    /// The series **On Deck** episode (#260): the most-recently-watched
    /// *in-progress* (resumable) episode, else the episode **following** the
    /// last one finished — computed across ALL seasons, not just the first
    /// season that happens to have an unwatched episode (which surfaced e.g.
    /// Season 3 while the user was mid-Season 7).
    private func computeNextUp() async {
        let episodes = await allShowEpisodes()
        guard !episodes.isEmpty else { nextUpEpisode = nil; nextUpResume = nil; return }

        var resumes: [MediaID: ResumePoint] = [:]
        for episode in episodes {
            if let point = await resumeStore.point(for: episode.id) { resumes[episode.id] = point }
        }

        let next = OnDeck.next(episodes: episodes) { episode in
            guard let resume = resumes[episode.id], !episode.isWatched else { return nil }
            return resume.updatedAt
        }
        nextUpEpisode = next
        nextUpResume = next.flatMap { resumes[$0.id] }
    }

    /// Seasons rarely carry their own cast — fetch the parent show's once, so
    /// the season page's Cast & Crew isn't empty (#267). No-op when the season
    /// has cast, the fallback is already loaded, or there's no parent to ask.
    private func loadFallbackCastIfNeeded() async {
        guard item.kind == .season, current.cast.isEmpty, fallbackCast.isEmpty,
              let source,
              let showID = activeItem.parentID ?? item.parentID,
              let show = try? await source.item(for: showID) else { return }
        fallbackCast = show.cast
    }

    private func selectSeason(_ season: MediaItem) {
        guard season.id != selectedSeason?.id else { return }
        selectedSeason = season
        seasonEpisodes = []
        // Note: the Next Up card tracks the whole series, so it deliberately
        // stays put when the user browses to a different season.
        Task { await loadSeasonEpisodes(season) }
    }

    /// Fetch resume points for a set of episodes into `episodeResume` (#260),
    /// merging so previously-loaded seasons keep theirs.
    private func loadEpisodeResumes(_ episodes: [MediaItem]) async {
        var map = episodeResume
        for episode in episodes {
            if let point = await resumeStore.point(for: episode.id) { map[episode.id] = point }
        }
        episodeResume = map
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
            await loadEpisodeResumes(episodes)
        } catch {
            guard selectedSeason?.id == season.id else { return }
            seasonEpisodes = []
        }
    }

    /// Hero title. For an **episode** with a known series, the series name is the
    /// big title and "S1 • E2 - Episode Title" sits beneath it (how Infuse / Apple
    /// TV present an episode); movies / shows / seasons — and episodes missing a
    /// series title — show their own title (#266 Detail Phase 1). When the source
    /// carries a **clearLogo**, the title renders as the stylized wordmark art
    /// instead of plain text (#273) — text-first, swapping in only once the image
    /// has actually loaded, so titles without a logo never flash a placeholder.
    @ViewBuilder
    private var heroTitleBlock: some View {
        if item.kind == .episode, let series = activeItem.seriesTitle, !series.isEmpty {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xxs) {
                Text(series)
                    .font(AetherDesign.Typography.heroTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                Text(DetailFormatting.episodeContext(activeItem))
                    .font(AetherDesign.Typography.sectionTitle)
                    .foregroundStyle(AetherDesign.Palette.textSecondary)
            }
        } else if let heroLogo {
            Image(uiImage: heroLogo)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: heroLogoMaxWidth, maxHeight: heroLogoMaxHeight, alignment: .leading)
                .accessibilityLabel(Text(activeItem.title))
        } else if item.kind == .season {
            // The formatter, not the raw title — a Czech-localized Plex sends
            // "7. řada", which should read "Season 7" (named seasons keep
            // their "S2 · Asylum" form).
            Text(DetailFormatting.seasonLabel(activeItem))
                .font(AetherDesign.Typography.heroTitle)
                .foregroundStyle(AetherDesign.Palette.textPrimary)
        } else {
            Text(activeItem.title)
                .font(AetherDesign.Typography.heroTitle)
                .foregroundStyle(AetherDesign.Palette.textPrimary)
        }
    }

    /// Logo caps — height-led (logos vary in aspect; `scaledToFit` follows).
    /// Generous on the 10-foot / spatial hero, compact on touch layouts.
    private var heroLogoMaxHeight: CGFloat {
        #if os(tvOS) || os(visionOS)
        140
        #else
        80
        #endif
    }

    private var heroLogoMaxWidth: CGFloat {
        #if os(tvOS) || os(visionOS)
        480
        #else
        280
        #endif
    }

    /// Dense single line, Infuse-style: "48 min • Jul 26, 2007 • [TV-14] • 1080p •
    /// DTS-HD MA 5.1" — runtime/date, the content-rating badge, then resolution +
    /// audio folded inline (they replace the old separate chip strip). The tech
    /// tail fills in when `mediaInfo` hydrates; the line reflows once, harmlessly.
    private var metadataRow: some View {
        HStack(spacing: AetherDesign.Spacing.xs) {
            Text(metadataParts.joined(separator: " • "))
                .font(AetherDesign.Typography.metadata)
                .foregroundStyle(AetherDesign.Palette.textSecondary)
            if let rating = current.contentRating {
                metadataDot
                contentRatingBadge(rating)
            }
            if !inlineTechParts.isEmpty {
                metadataDot
                Text(inlineTechParts.joined(separator: " • "))
                    .font(AetherDesign.Typography.metadata)
                    .foregroundStyle(AetherDesign.Palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The "•" separator used to splice the badge / tech tail into the line.
    private var metadataDot: some View {
        Text("•")
            .font(AetherDesign.Typography.metadata)
            .foregroundStyle(AetherDesign.Palette.textTertiary)
    }

    /// Resolution + HDR/DV + audio (codec + channels), folded into the metadata
    /// line — the glanceable subset of `mediaBadgeLabels` (the full breakdown
    /// stays in Technical Details). Empty until `mediaInfo` hydrates.
    private var inlineTechParts: [String] {
        guard let info = current.mediaInfo else { return [] }
        var parts: [String] = []
        if let resolution = info.videoResolution { parts.append(resolution) }
        if info.isDolbyVision {
            parts.append("Dolby Vision")
        } else if info.isHDR {
            parts.append("HDR")
        }
        if let audio = info.audioCodec?.uppercased() {
            if let channels = info.audioChannels {
                parts.append("\(audio) \(DetailFormatting.channelLabel(channels))")
            } else {
                parts.append(audio)
            }
        }
        return parts
    }

    /// The source's age/content classification as a thin-bordered badge —
    /// "PG-13", "TV-MA", "15" — sitting in the metadata line the way Infuse
    /// and Apple TV render it. Only shown when the source provided one.
    private func contentRatingBadge(_ rating: String) -> some View {
        Text(rating)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(AetherDesign.Palette.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(AetherDesign.Palette.textTertiary.opacity(0.6), lineWidth: 1)
            )
    }

    /// "Drama • Biography • History" — the genres line under the metadata, so the
    /// kind of title reads at a glance. Capped at four to avoid wrapping; hidden
    /// when the source carries none.
    @ViewBuilder
    private var genresRow: some View {
        if !current.genres.isEmpty {
            Text(current.genres.prefix(4).joined(separator: " • "))
                .font(AetherDesign.Typography.metadata)
                .foregroundStyle(AetherDesign.Palette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var metadataParts: [String] {
        // Shows describe themselves by run span + season/episode counts, not a
        // single runtime: "2011–Present • 8 Seasons • 73 Episodes • Series".
        if item.kind == .show { return seriesMetadataParts }
        if item.kind == .season { return seasonMetadataParts }
        var parts: [String] = []
        if item.kind == .episode {
            // Episode: runtime + air date. The series name and "S1 • E2 - Title"
            // live in the hero title block, so no year or "Episode" label here.
            if let runtime = activeItem.runtime { parts.append(DetailFormatting.runtime(runtime)) }
            if let date = activeItem.releaseDate { parts.append(DetailFormatting.airDate(date)) }
        } else {
            // Movie: year + runtime. The kind label is dropped — it's obvious and
            // the Infuse-style reference omits it — keeping the line dense.
            if let year = activeItem.year { parts.append(String(year)) }
            if let runtime = activeItem.runtime { parts.append(DetailFormatting.runtime(runtime)) }
        }
        return parts
    }

    /// Season Detail metadata line: "2022 • 10 Episodes • 7/10 watched" (#245,
    /// #267). "Season N" appears only when the hero title is a *named* season
    /// (e.g. "Asylum") — when the title already reads "Season N", repeating it
    /// here said nothing. Reads `current`/`children` so hydrated counts fill in
    /// after the detail endpoint resolves.
    private var seasonMetadataParts: [String] {
        var parts: [String] = []
        if let number = current.seasonNumber, current.title != "Season \(number)" {
            parts.append("Season \(number)")
        }
        if let year = current.year { parts.append(String(year)) }
        let count = current.episodeCount ?? (children.isEmpty ? nil : children.count)
        if let count, count > 0 { parts.append("\(count) Episode\(count == 1 ? "" : "s")") }
        // Watch progress from the loaded episodes: "Watched" when done, else
        // "7/10 watched" once anything's been seen.
        if !children.isEmpty, children.allSatisfy({ $0.kind == .episode }) {
            let watched = children.filter(\.isWatched).count
            if watched == children.count {
                parts.append("Watched")
            } else if watched > 0 {
                parts.append("\(watched)/\(children.count) watched")
            }
        }
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
                labels.append("\(audio) \(DetailFormatting.channelLabel(channels))")
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

    // MARK: - Cast & Crew

    /// Cast for the screen — the item's own, else the parent show's (seasons
    /// rarely carry cast of their own, #267).
    private var displayCast: [CastMember] {
        current.cast.isEmpty ? fallbackCast : current.cast
    }

    /// Horizontal rail of cast + key crew with circular headshots — the biggest
    /// information-density gap vs. Infuse. Hidden when the source carries none.
    @ViewBuilder
    private var castSection: some View {
        if !displayCast.isEmpty {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
                Text("Cast & Crew")
                    .font(AetherDesign.Typography.sectionTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: AetherDesign.Spacing.m) {
                        ForEach(displayCast) { member in castCard(member) }
                    }
                    .padding(.vertical, AetherDesign.Spacing.xxs)
                    .padding(.horizontal, 2)
                }
                // No `.focusSection()` on tvOS: the cards are non-focusable
                // metadata (#249), so the focus engine skips the whole rail and
                // moves cleanly between the sections above and below it.
            }
        }
    }

    private func castCard(_ member: CastMember) -> some View {
        // Cast is passive, informational metadata: the cards do nothing when
        // selected (no actor pages yet). On tvOS that means NON-focusable — a
        // focusable card with no destination just traps focus and makes leaving
        // the section hard (#249). So render the plain static card everywhere;
        // when actor detail pages exist this can become interactive again.
        CastCardContent(member: member, size: castPhotoSize)
    }

    private var castPhotoSize: CGFloat {
        #if os(tvOS)
        180   // larger cards on TV — cast is a first-class browse destination
        #else
        84
        #endif
    }

    /// One cast/crew card. Reads `\.isFocused` directly so tvOS focus is
    /// unmistakable from across the room — a big scale jump, an accent ring on
    /// the headshot, a blue glow, and a lift. On platforms with no focus engine
    /// it renders the calm static card unchanged.
    private struct CastCardContent: View {
        let member: CastMember
        let size: CGFloat
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            VStack(spacing: AetherDesign.Spacing.xs) {
                photo
                Text(member.name)
                    .font(AetherDesign.Typography.caption.weight(.medium))
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                    .lineLimit(1)
                if let role = member.role {
                    Text(role)
                        .font(AetherDesign.Typography.caption)
                        .foregroundStyle(isFocused ? AetherDesign.Palette.textSecondary : AetherDesign.Palette.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(width: size)
            .multilineTextAlignment(.center)
            .scaleEffect(isFocused ? 1.18 : 1.0)
            .animation(AetherDesign.Motion.focus, value: isFocused)
        }

        private var photo: some View {
            ZStack {
                Circle().fill(AetherDesign.Palette.surfaceElevated)
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.38))
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
                if member.photoURL != nil {
                    CachedAsyncImage(url: member.photoURL, aspectRatio: 1, maxPixel: ArtworkTier.thumbnail.maxPixel)
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay {
                Circle().strokeBorder(AetherDesign.Palette.accent, lineWidth: isFocused ? 4 : 0)
            }
            .shadow(
                color: AetherDesign.Palette.accent.opacity(isFocused ? 0.7 : 0.0),
                radius: isFocused ? 24 : 0, y: isFocused ? 10 : 0
            )
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
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xxs) {
                Text("Available Sources")
                    .font(AetherDesign.Typography.sectionTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                // Unified Library framing — this title exists on more than one
                // connected server; the row marks which one is playing.
                Text("Play this title from any connected source.")
                    .font(AetherDesign.Typography.caption)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
            }

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
        favoriteOverride = nil  // …and its own favorite state
        overrideItem = (src.item.id == item.id) ? nil : src.item
    }

    // MARK: - Action row (Resume / Play From Beginning / Play, or unavailable)

    @ViewBuilder
    private var actionRow: some View {
        if current.streamURL != nil {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
                // Primary actions as a single horizontal pill row (Infuse-style),
                // Resume carrying its position inline — a compact cluster instead
                // of a tall Resume / caption / Restart stack (#266 Detail Phase 1).
                // Pills come first so the tvOS remote still lands on Play/Resume on
                // arrival (not the watched toggle).
                HStack(spacing: AetherDesign.Spacing.m) {
                    if resume != nil { resumeButton } else { playButton }
                    if resume != nil { restartButton }
                    #if os(visionOS)
                    watchInCinemaButton
                    #endif
                }
                // Tertiary actions as a compact, equal-weight icon row beneath.
                compactActionRow
                // The first-use hint is a touch affordance (tap "Got it" / tap an
                // icon). On tvOS it created an unreachable focus dead-zone, and
                // the remote already moves focus across the labelled icons — so
                // it's iOS / iPadOS / visionOS only.
                #if !os(tvOS)
                compactActionHint
                #endif
            }
        } else {
            unavailableState
        }
    }

    /// First-use discoverability for the bare icon row (§4, "bare + first-use
    /// hint"): a one-time caption naming the icons that are actually present,
    /// dismissed by "Got it" — or by tapping an icon, since that *is* discovery.
    /// `iconHintSeen` persists, so the row is clean forever after.
    @ViewBuilder
    private var compactActionHint: some View {
        let items = compactActionHintItems
        if !iconHintSeen, !items.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: AetherDesign.Spacing.xs) {
                Image(systemName: "hand.tap")
                    .font(.caption2)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
                Text(items.joined(separator: " · "))
                    .font(AetherDesign.Typography.caption)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: AetherDesign.Spacing.s)
                Button("Got it") { dismissIconHint() }
                    .font(AetherDesign.Typography.caption.weight(.semibold))
                    .foregroundStyle(AetherDesign.Palette.accent)
                    .buttonStyle(.plain)
                    .premiumFocus()
            }
            .padding(.top, AetherDesign.Spacing.xxs)
            .transition(.opacity)
        }
    }

    /// Labels for whichever compact icons are currently visible, left-to-right.
    private var compactActionHintItems: [String] {
        var items: [String] = []
        if shouldShowDownloadControl { items.append("Download") }
        if source != nil { items.append("Watch status") }
        if source?.supportsFavorites == true { items.append("Favorite") }
        if availableSources.count > 1 { items.append("Source") }
        if current.mediaInfo != nil { items.append("Details") }
        return items
    }

    private func dismissIconHint() {
        guard !iconHintSeen else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { iconHintSeen = true }
    }

    /// Tertiary actions as a row of compact circular icon buttons (Infuse-style)
    /// so they never compete with Resume/Play. Each is a focusable `Button` /
    /// `Menu`, so the whole row is reachable left/right by the tvOS remote.
    private var compactActionRow: some View {
        HStack(spacing: AetherDesign.Spacing.m) {
            if shouldShowDownloadControl {
                downloadIconButton
            }
            if source != nil {
                AetherIconButton(
                    systemImage: isWatched ? "eye.fill" : "eye",
                    accessibilityLabel: isWatched ? "Mark as unwatched" : "Mark as watched",
                    isActive: isWatched
                ) {
                    dismissIconHint()
                    Task { await toggleWatched() }
                }
            }
            if source?.supportsFavorites == true {
                AetherIconButton(
                    systemImage: isFavorite ? "heart.fill" : "heart",
                    accessibilityLabel: isFavorite ? "Remove from favorites" : "Add to favorites",
                    isActive: isFavorite
                ) {
                    dismissIconHint()
                    Task { await toggleFavorite() }
                }
            }
            if availableSources.count > 1 {
                sourceMenuButton
            }
            if current.mediaInfo != nil {
                AetherIconButton(systemImage: "info.circle", accessibilityLabel: "Technical details") {
                    dismissIconHint()
                    presentedSelector = .technicalDetails
                }
            }
            #if !os(tvOS)
            // Edit metadata — local items only (movies / episodes, not show
            // containers, whose id is "show:<series>" rather than an item id).
            if activeItem.id.source == .local && !activeItem.kind.isContainer {
                AetherIconButton(systemImage: "pencil", accessibilityLabel: "Edit metadata") {
                    dismissIconHint()
                    presentedSelector = .editMetadata
                }
            }
            #endif
            Spacer(minLength: 0)
        }
    }

    /// Source switcher as a compact icon `Menu` (only shown when the title is on
    /// more than one source). Mirrors the "Available Sources" section's switching.
    private var sourceMenuButton: some View {
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
            AetherIconCircleLabel(systemImage: "rectangle.2.swap")
        }
        .accessibilityLabel("Switch source")
    }

    /// Download as a compact icon `Menu`: the glyph reflects the current state,
    /// and the menu offers the state-appropriate actions (download / pause /
    /// resume / cancel / delete / retry), with the live status as a header.
    private var downloadIconButton: some View {
        Menu {
            downloadMenuContent
        } label: {
            AetherIconCircleLabel(
                systemImage: downloadGlyph,
                isActive: isDownloaded
            )
        }
        .accessibilityLabel("Download")
    }

    /// True once the title is fully downloaded — tints the download icon as "done".
    private var isDownloaded: Bool {
        if case .completed = downloadStatus { return true }
        return false
    }

    private var downloadGlyph: String {
        switch downloadStatus {
        case .notDownloaded:            return "arrow.down.circle"
        case .queued, .downloading:     return "arrow.down.circle.dotted"
        case .paused:                   return "pause.circle"
        case .completed:                return "checkmark.circle.fill"
        case .failed:                   return "exclamationmark.circle"
        case .expired:                  return "arrow.clockwise.circle"
        }
    }

    @ViewBuilder
    private var downloadMenuContent: some View {
        switch downloadStatus {
        case .notDownloaded:
            Button {
                presentedSelector = .downloadQuality
            } label: { Label("Download", systemImage: "arrow.down.circle") }
            .disabled(isEnqueuingDownload)
        case .queued:
            Text("Queued")
            Button(role: .destructive) { Task { await cancelDownload() } } label: { Label("Cancel", systemImage: "xmark") }
        case let .downloading(fraction):
            Text("Downloading · \(DetailFormatting.percent(fraction))")
            Button { Task { await pauseDownload() } } label: { Label("Pause", systemImage: "pause") }
            Button(role: .destructive) { Task { await cancelDownload() } } label: { Label("Cancel", systemImage: "xmark") }
        case let .paused(fraction):
            Text("Paused at \(DetailFormatting.percent(fraction))")
            Button { Task { await resumeDownload() } } label: { Label("Resume", systemImage: "play") }
            Button(role: .destructive) { Task { await cancelDownload() } } label: { Label("Cancel", systemImage: "xmark") }
        case let .completed(_, size):
            Text("Downloaded · \(formatBytes(size))")
            Button(role: .destructive) { Task { await removeDownload() } } label: { Label("Delete Download", systemImage: "trash") }
        case let .failed(reason):
            Text("Failed · \(reason)")
            Button { Task { await retryDownload() } } label: { Label("Retry", systemImage: "arrow.clockwise") }
        case .expired:
            Text("Expired")
            Button { Task { await retryDownload() } } label: { Label("Re-download", systemImage: "arrow.clockwise") }
        }
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

    /// Favorite state — the optimistic override wins over the source's value so
    /// the heart flips instantly on tap.
    private var isFavorite: Bool { favoriteOverride ?? current.isFavorite }

    private func toggleFavorite() async {
        guard let source, source.supportsFavorites else { return }
        let next = !isFavorite
        favoriteOverride = next   // optimistic
        await source.setFavorite(activeItem.id, to: next)
    }

    /// True when a Download surface should appear below the play buttons —
    /// only for Plex / Jellyfin items (the only sources that implement
    /// `downloadURL`), and only once the pipeline has booted.
    private var shouldShowDownloadControl: Bool {
        guard downloadManager != nil, source?.supportsDownloads == true else { return false }
        return true
    }

    /// "47%" — keeps the row stable as progress ticks (no decimals,
    /// always two digits at most).

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
    /// Enters Cinema Mode. When a resume point exists, first asks whether to
    /// continue or start over (the immersive entry has no Resume/Restart pair of
    /// its own); otherwise starts from the top.
    private var watchInCinemaButton: some View {
        AetherButton(
            "Watch in Cinema",
            systemImage: "visionpro",
            role: .secondary
        ) {
            if resume != nil {
                showCinemaResumePrompt = true
            } else {
                Task { await watchInCinema(fromStart: false) }
            }
        }
        .disabled(isPreparingPlayback)
        .confirmationDialog(
            "Watch in Cinema",
            isPresented: $showCinemaResumePrompt,
            titleVisibility: .visible
        ) {
            Button(resume.map { "Continue from \(DetailFormatting.position($0.position))" } ?? "Continue") {
                Task { await watchInCinema(fromStart: false) }
            }
            Button("Start Over") {
                Task { await watchInCinema(fromStart: true) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
    #endif

    /// Primary action when a resume point exists — the position is carried
    /// **inline** in the label ("Resume 0:01:39") like the Infuse reference, so it
    /// sits as one pill next to Restart instead of a button + caption stack.
    private var resumeButton: some View {
        AetherButton(
            isPreparingPlayback ? "Preparing…" : "Resume \(DetailFormatting.position(resume?.position ?? .zero))",
            systemImage: "play.fill",
            role: .primary
        ) {
            Task { await presentPlayer(fromStart: false) }
        }
        .disabled(isPreparingPlayback)
    }

    /// Level 2 — Restart, secondary emphasis, sitting under Resume.
    private var restartButton: some View {
        AetherButton(
            "Restart",
            systemImage: "backward.end.fill",
            role: .secondary
        ) {
            Task { await presentPlayer(fromStart: true) }
        }
        .disabled(isPreparingPlayback)
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
        #if !os(tvOS)
        case .editMetadata:
            LocalMetadataEditSheet(itemID: activeItem.id.rawValue) {
                presentedSelector = nil
                localEditToken = UUID()   // force a re-hydrate on dismiss
            }
        #endif
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
    /// The Technical Details rows, shared by the always-expanded sheet
    /// (`mediaSection`) and the collapsible on-page section.
    @ViewBuilder
    private func mediaInfoRows(_ info: MediaInfo?) -> some View {
        if let video = DetailFormatting.videoLine(info) {
            AetherSettingsRow(label: "Video", value: video)
        }
        if let audio = DetailFormatting.audioLine(info) {
            AetherSettingsRow(label: "Audio", value: audio)
        }
        if let subtitles = subtitleSummary {
            AetherSettingsRow(label: "Subtitles", value: subtitles)
        }
        if let hdrBadge = DetailFormatting.hdrBadge(info) {
            AetherSettingsRow(label: "HDR", value: hdrBadge)
        }
        if let bitrate = info?.bitrateKbps, bitrate > 0 {
            AetherSettingsRow(label: "Bitrate", value: DetailFormatting.bitrate(bitrate))
        }
        if let size = info?.fileSizeBytes, size > 0 {
            AetherSettingsRow(label: "File Size", value: DetailFormatting.fileSize(size))
        }
        AetherSettingsRow(label: "Playback", status: playbackModeStatus)
        if let source {
            AetherSettingsRow(label: "Source", value: source.displayName)
        }
    }

    /// Always-expanded section — used inside the Technical Details *sheet*
    /// (reached from the compact icon row).
    @ViewBuilder
    private var mediaSection: some View {
        AetherSettingsSection("Technical Details") {
            mediaInfoRows(current.mediaInfo)
        }
    }

    /// On-page **collapsible** Technical Details — defaults collapsed so the
    /// info is available without padding out the page (§6). The header toggles;
    /// the rows live in the same frosted card `AetherSettingsSection` uses.
    @ViewBuilder
    private var technicalDetailsSection: some View {
        // tvOS: always-expanded (no toggle). The collapsible disclosure animated
        // a layout/height change inside the focusable ScrollView, which could
        // corrupt focus geometry — scrolling down to More Like This and back up
        // sometimes lost the top menu. A static section avoids that and also
        // matches the "richer, always-visible tech details on TV" feedback.
        #if os(tvOS)
        mediaSection
        #else
        collapsibleTechnicalDetailsSection
        #endif
    }

    private var collapsibleTechnicalDetailsSection: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.s) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    technicalDetailsExpanded.toggle()
                }
            } label: {
                HStack(spacing: AetherDesign.Spacing.xs) {
                    Text("Technical Details".uppercased())
                        .font(AetherDesign.Typography.caption)
                        .foregroundStyle(AetherDesign.Palette.textTertiary)
                        .tracking(0.6)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(AetherDesign.Palette.textTertiary)
                        .rotationEffect(.degrees(technicalDetailsExpanded ? 0 : -90))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, AetherDesign.Spacing.m)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .premiumFocus()

            if technicalDetailsExpanded {
                VStack(spacing: 0) {
                    mediaInfoRows(current.mediaInfo)
                }
                .background(
                    AetherDesign.Materials.card,
                    in: RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                        .strokeBorder(AetherDesign.Palette.separator, lineWidth: 1)
                }
                .transition(.opacity)
            }
        }
    }

    /// Subtitle languages as a compact list — "English, Czech, Spanish +2".
    /// Localises the track's language code when present (Plex sends "eng" /
    /// "ces"), else falls back to the track's display title. Only the
    /// transcode path carries per-track subtitle metadata, so this stays
    /// hidden for direct-play items rather than showing a half-truth.
    private var subtitleSummary: String? {
        var seen = Set<String>()
        var ordered: [String] = []
        for track in current.subtitleTracks {
            guard let name = DetailFormatting.subtitleName(track) else { continue }
            if seen.insert(name.lowercased()).inserted { ordered.append(name) }
        }
        guard !ordered.isEmpty else { return nil }
        let shown = ordered.prefix(4).joined(separator: ", ")
        return ordered.count > 4 ? "\(shown) +\(ordered.count - 4)" : shown
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
            // Don't clobber a pick the user made while this hydrate was in
            // flight (#68) — carry any explicit selections onto the fresh item.
            configuredItem = preservingUserSelections(on: applyingPreferences(to: hydrated))
        }
    }

    /// Seeds the user's app-wide playback defaults onto a freshly hydrated
    /// item (audio/subtitle language + default quality). The logic lives on
    /// `PlaybackPreferencesStore.applied(to:)` in AetherCore so every player
    /// entry point — including Auto-Play-Next — shares it (#68).
    private func applyingPreferences(to hydrated: MediaItem) -> MediaItem {
        playbackPreferences?.applied(to: hydrated) ?? hydrated
    }

    /// Re-applies the session's explicit picker choices (audio / subtitles /
    /// quality) from the current `configuredItem` onto `fresh`, so a re-hydrate
    /// never silently reverts what the user just selected (#68).
    private func preservingUserSelections(on fresh: MediaItem) -> MediaItem {
        guard let existing = configuredItem, existing.id == fresh.id else { return fresh }
        var result = fresh
        if let track = existing.selectedAudioTrack,
           let match = result.audioTracks.first(where: { $0.id == track.id }) {
            result = result.selectingAudioTrack(match)
        }
        if let track = existing.selectedSubtitleTrack,
           let match = result.subtitleTracks.first(where: { $0.id == track.id }) {
            result = result.selectingSubtitleTrack(match)
        } else if existing.selectedSubtitleTrackID == nil, !existing.subtitleTracks.isEmpty {
            result = result.selectingSubtitleTrack(nil)   // explicit "Off" survives
        }
        result = result.selectingQuality(existing.selectedQuality)
        return result
    }

    // MARK: - Player dismiss

    /// Identifies a file routed to the VLCKit engine (for `.fullScreenCover`).
    private struct VLCPlayback: Identifiable {
        let id = UUID()
        let url: URL
    }

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
            // Same seeding as the on-appear hydrate — without it, a fast Play
            // before hydration resolved dropped the default-language prefs (#68).
            configuredItem = applyingPreferences(to: hydrated)
        }
        playbackItem = current

        // Local files AVFoundation can't demux (mkv, …) play through the VLCKit
        // engine instead of the AVKit player. Resume / Cinema stay AVPlayer-only
        // for now (fast-follow on this engine).
        if let url = current.streamURL, PlaybackEngine.engine(for: url) == .vlc {
            vlcPlayback = VLCPlayback(url: url)
            return
        }

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
            // Same seeding as the on-appear hydrate — without it, a fast Play
            // before hydration resolved dropped the default-language prefs (#68).
            configuredItem = applyingPreferences(to: hydrated)
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

    /// Bolder, couch-visible focus for season cards — a brighter accent glow and
    /// extra lift on top of the card's own focus, since the default lift alone was
    /// hard to identify from across the room (#266 feedback). tvOS only.
    @ViewBuilder
    func seasonCardFocus() -> some View {
        #if os(tvOS)
        modifier(SeasonCardFocus())
        #else
        self
        #endif
    }
}

#if os(tvOS)
private struct SeasonCardFocus: ViewModifier {
    @Environment(\.isFocused) private var isFocused
    func body(content: Content) -> some View {
        content
            .scaleEffect(isFocused ? 1.08 : 1.0)
            .shadow(
                color: AetherDesign.Palette.accent.opacity(isFocused ? 0.9 : 0),
                radius: isFocused ? 30 : 0,
                y: isFocused ? 12 : 0
            )
            .zIndex(isFocused ? 1 : 0)
            .animation(AetherDesign.Motion.focus, value: isFocused)
    }
}
#endif
