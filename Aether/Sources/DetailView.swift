import SwiftUI
#if canImport(UIKit)
import UIKit   // UIViewController / UIHostingController for the visionOS cinema Info-panel tab
#endif
import AetherCore

/// Navigation value that opens an item's Detail **and immediately starts
/// playback** (#382). Used by the show "Play S1E1 · Pilot" pill so one tap plays
/// the on-deck episode, while still reusing the episode's own Detail playback
/// path (hydration, language prefs, VLC/SMB engine, resume) rather than
/// reimplementing it at the show level. Distinct from a plain `MediaItem` nav so
/// only this entry point autoplays — opening the episode any other way doesn't.
struct EpisodeAutoplayRoute: Hashable {
    let item: MediaItem
}

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
    let availableSources: [UnifiedSource]
    /// Start playback automatically once the screen has hydrated (#382). Set by
    /// the `EpisodeAutoplayRoute` destination so the show "Play S1E1" pill plays
    /// the on-deck episode on one tap while still routing through the episode's
    /// own, well-tested Detail playback path. `false` everywhere else.
    let autoplay: Bool

    /// The data / business state for this screen (#241). Owned by the view as
    /// `@State` and created once per navigation identity — `navigationDestination`
    /// gives a fresh DetailView (and so a fresh VM) per pushed item.
    @State private var viewModel: DetailViewModel

    // MARK: - Presentation state (stays in the view)

    /// Drives the "mark an in-progress title watched?" confirmation — marking
    /// watched discards the resume point, so it asks first.
    @State private var confirmMarkWatched = false
    @State private var isPlayerPresented = false
    /// Set when a local file needs the VLCKit engine (mkv etc.) instead of AVKit.
    @State private var vlcPlayback: VLCPlayback?
    #if os(visionOS)
    /// visionOS: drives the "Continue or Start Over" prompt before entering
    /// Cinema Mode when a resume point exists.
    @State private var showCinemaResumePrompt = false
    #endif
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
    /// Which compact selector sheet is currently presented on Detail. `nil`
    /// = nothing open; tapping a disclosure row sets one. iOS / iPadOS uses
    /// `.presentationDetents([.medium])` so the picker takes about half the
    /// screen and the Detail backdrop is still visible behind.
    @State private var presentedSelector: PlaybackSelector?
    // Set when the local metadata editor closes, to re-point the screen at the
    // edited item so its title / poster / overview repaint (#211). Seeded nil so
    // the re-hydrate task below is a no-op on first appear (no double fetch).
    @State private var localEditToken: UUID?
    /// Technical Details starts tucked — rich info without cluttering the page.
    @State private var technicalDetailsExpanded = false
    /// Guards the one-shot autoplay (#382) so re-running the load task (source
    /// switch, scene re-activation) can't relaunch the player after the user has
    /// already dismissed it.
    @State private var didAutoplay = false

    // MARK: - DetailViewModel forwarders (#241 inc 1)
    // Same-named computed forwarders so the section builders and load / mutate
    // funcs compile untouched while the data state lives in the VM. `@Observable`
    // tracking works through these because the `viewModel.x` read happens during
    // body evaluation. Inlined away as funcs migrate in later increments.

    private var resume: ResumePoint? {
        get { viewModel.resume }
        nonmutating set { viewModel.resume = newValue }
    }
    private var overrideItem: MediaItem? {
        get { viewModel.overrideItem }
        nonmutating set { viewModel.overrideItem = newValue }
    }
    private var advancedItem: MediaItem? {
        get { viewModel.advancedItem }
        nonmutating set { viewModel.advancedItem = newValue }
    }
    private var watchedOverride: Bool? {
        get { viewModel.watchedOverride }
        nonmutating set { viewModel.watchedOverride = newValue }
    }
    private var favoriteOverride: Bool? {
        get { viewModel.favoriteOverride }
        nonmutating set { viewModel.favoriteOverride = newValue }
    }
    private var playbackItem: MediaItem? {
        get { viewModel.playbackItem }
        nonmutating set { viewModel.playbackItem = newValue }
    }
    private var playbackStartAt: Double? {
        get { viewModel.playbackStartAt }
        nonmutating set { viewModel.playbackStartAt = newValue }
    }
    private var isPreparingPlayback: Bool {
        get { viewModel.isPreparingPlayback }
        nonmutating set { viewModel.isPreparingPlayback = newValue }
    }
    private var launchingInCinema: Bool {
        get { viewModel.launchingInCinema }
        nonmutating set { viewModel.launchingInCinema = newValue }
    }
    private var children: [MediaItem] {
        get { viewModel.children }
        nonmutating set { viewModel.children = newValue }
    }
    private var isLoadingChildren: Bool {
        get { viewModel.isLoadingChildren }
        nonmutating set { viewModel.isLoadingChildren = newValue }
    }
    private var related: [MediaItem] {
        get { viewModel.related }
        nonmutating set { viewModel.related = newValue }
    }
    private var selectedSeason: MediaItem? {
        get { viewModel.selectedSeason }
        nonmutating set { viewModel.selectedSeason = newValue }
    }
    private var seasonEpisodes: [MediaItem] {
        get { viewModel.seasonEpisodes }
        nonmutating set { viewModel.seasonEpisodes = newValue }
    }
    private var isLoadingEpisodes: Bool {
        get { viewModel.isLoadingEpisodes }
        nonmutating set { viewModel.isLoadingEpisodes = newValue }
    }
    private var nextUpEpisode: MediaItem? {
        get { viewModel.nextUpEpisode }
        nonmutating set { viewModel.nextUpEpisode = newValue }
    }
    private var nextUpResume: ResumePoint? {
        get { viewModel.nextUpResume }
        nonmutating set { viewModel.nextUpResume = newValue }
    }
    private var episodeResume: [MediaID: ResumePoint] {
        get { viewModel.episodeResume }
        nonmutating set { viewModel.episodeResume = newValue }
    }
    private var fallbackCast: [CastMember] {
        get { viewModel.fallbackCast }
        nonmutating set { viewModel.fallbackCast = newValue }
    }
    private var parentSeason: MediaItem? {
        get { viewModel.parentSeason }
        nonmutating set { viewModel.parentSeason = newValue }
    }
    private var parentShow: MediaItem? {
        get { viewModel.parentShow }
        nonmutating set { viewModel.parentShow = newValue }
    }
    private var heroLogo: AetherPlatformImage? {
        get { viewModel.heroLogo }
        nonmutating set { viewModel.heroLogo = newValue }
    }
    private var configuredItem: MediaItem? {
        get { viewModel.configuredItem }
        nonmutating set { viewModel.configuredItem = newValue }
    }
    private var isEnqueuingDownload: Bool {
        get { viewModel.isEnqueuingDownload }
        nonmutating set { viewModel.isEnqueuingDownload = newValue }
    }
    /// The app session — used to mark watched/unwatched on **every** connected
    /// source that has the title (not just the one Detail is acting on), so a
    /// movie on both Plex and Jellyfin stays in sync (#232 follow-up).
    @Environment(AppSession.self) private var appSession
    /// For the "Play on Netflix" link-out (#360).
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Drives the backdrop layout: compact (iPhone) → full-width 16:9; regular
    /// (iPad / tvOS / visionOS) → edge-to-edge fill at a fixed height.
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.dismiss) private var dismiss
    /// App language locale (#320) — release dates format in this locale.
    @Environment(\.locale) private var locale
    /// Watched dimming + label preference, so episode-row stills match the
    /// poster cards' watched treatment (#280 follow-up).
    @Environment(\.watchedDisplay) private var watchedDisplay
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
        case smbEditMetadata
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
            case .smbEditMetadata: return "smbEditMetadata"
            #endif
            }
        }
    }

    /// The source the screen is currently acting on (#241: body lives in the VM,
    /// forwarded here so the section builders read it unchanged).
    private var activeItem: MediaItem { viewModel.activeItem }

    /// Whether a source id is an SMB share (drives the title/year editor, #213).
    private func isSMBSource(_ source: MediaSourceID) -> Bool {
        if case .smb = source { return true }
        return false
    }

    /// The item reflecting hydration + the user's track / quality selections.
    private var current: MediaItem { viewModel.current }

    /// The connector for the shown item (#241: derived in the VM).
    private var source: (any MediaSource)? { viewModel.source }

    /// Download status for this item (#241: derived in the VM).
    private var downloadStatus: DownloadStatus { viewModel.downloadStatus }

    init(
        item: MediaItem,
        connectedSources: [any MediaSource],
        resumeStore: ResumeStore,
        playbackSession: PlaybackSession,
        downloadManager: DownloadManager?,
        downloads: DownloadObserver?,
        playbackPreferences: PlaybackPreferencesStore?,
        availableSources: [UnifiedSource] = [],
        autoplay: Bool = false
    ) {
        self.item = item
        self.connectedSources = connectedSources
        self.resumeStore = resumeStore
        self.playbackSession = playbackSession
        self.downloadManager = downloadManager
        self.downloads = downloads
        self.playbackPreferences = playbackPreferences
        self.availableSources = availableSources
        self.autoplay = autoplay
        _viewModel = State(initialValue: DetailViewModel(
            item: item,
            connectedSources: connectedSources,
            resumeStore: resumeStore,
            downloadManager: downloadManager,
            downloads: downloads,
            playbackPreferences: playbackPreferences,
            availableSources: availableSources
        ))
    }

    var body: some View {
        ZStack {
            // The title's artwork as the page's environment (#290) — pinned
            // behind all content so Detail reads as one continuous cinematic
            // scene instead of a hero band that ends above a flat dark surface.
            if !isPlayerPresented {
                cinematicDetailBackground
            }
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
                        #if os(iOS)
                        // iPad full-screen landscape (regular width): a two-column
                        // functional layout uses the trailing half instead of
                        // letting it sit empty over a dark backdrop (#379). Narrow
                        // splits stay compact (single column), and tvOS / visionOS
                        // keep the cinematic backdrop-through `wideContent`.
                        if hSizeClass == .regular {
                            twoColumnContent
                        } else {
                            wideContent
                        }
                        #else
                        wideContent
                        #endif
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
                    onDismiss: dismissPlayer,
                    onAdvance: { advancedItem = $0 }
                )
                .transition(.opacity)
                .zIndex(10)
                #if os(iOS)
                .statusBarHidden()
                #endif
            }
        }
        // `cinematicDetailBackground` is the screen background now (#290); it
        // carries its own base colour, so no flat `aetherScreenBackground` here.
        // The player overlay paints its own black when presented.
        .background(AetherDesign.Palette.background)
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
            if item.kind == .episode {
                await loadEpisodeParents()   // #282: Season / Show navigation
            }
            // One-shot autoplay (#382): the show "Play S1E1" pill routes here
            // with `autoplay` set. Hydration is done, so launch the player now —
            // `fromStart: false` resumes from the saved point when the on-deck
            // episode is in progress, else starts from the top. Guarded so a
            // later task re-run (source switch / re-activation) can't relaunch.
            if autoplay, !didAutoplay {
                didAutoplay = true
                await presentPlayer(fromStart: false)
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
                  activeItem.id.source == .local || isSMBSource(activeItem.id.source),
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
            // SMB has no pre-play track list, so hand the player the app's default
            // audio/subtitle languages — it applies the matching tracks once VLC
            // parses them ("choose before you watch", driven by Settings).
            VLCPlayerView(
                url: playback.url,
                options: playback.options,
                preferredAudioLanguage: playbackPreferences?.defaultAudioLanguage,
                preferredSubtitleLanguage: playbackPreferences?.defaultSubtitleLanguage
            ) { vlcPlayback = nil }
                .ignoresSafeArea()
        }
        .confirmationDialog(
            "Mark as Watched?",
            isPresented: $confirmMarkWatched,
            titleVisibility: .visible
        ) {
            Button("Mark as Watched") { Task { await setWatched(true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This title is in progress. Marking it watched removes it from Continue Watching.")
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
                    // Hero artwork now comes from the full-screen cinematic
                    // background (#290) — reserve the band height so the title
                    // sits below it, over the art, with no second backdrop.
                    // On iPhone, shows use a shorter band so the Continue
                    // Watching / Next Up card and Seasons aren't pushed below
                    // the fold (#337) — the resume action is a series' primary CTA.
                    Color.clear
                        .frame(height: compactHeroBandHeight)

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

                    episodeParentNavigation
                        .padding(.horizontal, AetherDesign.Spacing.l)

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

                    // tvOS reaches the full technical details via the info icon
                    // in the action row → a focused, scrollable sheet — the
                    // inline section was clipped + competed with primary content
                    // (#281). Other platforms keep it inline (collapsed).
                    #if !os(tvOS)
                    if !item.kind.isContainer, current.mediaInfo != nil {
                        technicalDetailsSection
                            .padding(.horizontal, AetherDesign.Spacing.l)
                            .frame(maxWidth: 720, alignment: .leading)
                    }
                    #endif

                    // Only meaningful when the title exists on more than one source.
                    if availableSources.count > 1 {
                        sourceSwitcher
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
            // Pin the column to the viewport's leading edge. Without this the
            // VStack sizes to its widest child; the instant any child resolves
            // wider than the screen, a leading-aligned VStack with no width
            // constraint gets centered and its left edge — "Episodes", the
            // leading halves of the stills — slides off the iPad-portrait
            // screen. `movieContent` avoids this by anchoring its hero to
            // `size.width`; `wideContent` via an explicit pin. `scrollContent`
            // was the only layout missing one (the iPad-portrait episode clip).
            .frame(maxWidth: .infinity, alignment: .leading)
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
            // Backdrop comes from the full-screen cinematic background (#290) now;
            // keep just the readability scrim over it for the left content column.
            wideScrim
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

                        episodeParentNavigation

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
                        #if !os(tvOS)
                        if !item.kind.isContainer, current.mediaInfo != nil {
                            technicalDetailsSection
                        }
                        #endif
                        if availableSources.count > 1 {
                            sourceSwitcher
                        }
                    }
                    .frame(maxWidth: wideColumnWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Episodes have no rail between this column and Cast & Crew, so
                    // make the (full-width) column a focus section → Up from any
                    // cast card lands here at any scroll offset (#359). Containers
                    // (seasons) opt out: their episodes rail already brackets cast,
                    // and the nested Next-Up section (#266) must stay the rail's Up
                    // target rather than being shadowed by an outer column section.
                    .aetherDetailFocusSection(when: !item.kind.isContainer)
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

    #if os(iOS)
    // MARK: - iPad landscape two-column layout (#379)

    /// Fixed trailing-column width — wide enough for a Cast headshot rail and
    /// the Technical Details rows, narrow enough to leave the primary content
    /// (title, actions, episode list) the roomy leading column.
    private var trailingColumnWidth: CGFloat { 360 }

    /// iPad full-screen landscape detail: the primary content stays in a roomy
    /// leading column, while the secondary detail (Technical Details, Cast &
    /// Crew) moves into a trailing column so the right half of the screen is
    /// used instead of sitting empty over a dark backdrop (#379). One shared
    /// vertical scroll; both columns are top-aligned. tvOS / visionOS keep the
    /// cinematic single-column `wideContent`.
    private var twoColumnContent: some View {
        ZStack(alignment: .topLeading) {
            wideScrim
                .ignoresSafeArea()

            ScrollView {
                HStack(alignment: .top, spacing: AetherDesign.Spacing.xl) {
                    // Leading column — primary content (mirrors `wideContent`'s
                    // left column, minus the secondary sections moved right).
                    VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                        heroTitleBlock
                        metadataRow
                        genresRow

                        if !item.kind.isContainer {
                            actionRow
                        }

                        episodeParentNavigation

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

                        if item.kind == .season {
                            nextUpCard
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if !item.kind.isContainer, current.streamURL != nil {
                            playbackSection
                        }

                        if availableSources.count > 1 {
                            sourceSwitcher
                        }

                        // Episode list (season page) — the primary browse target,
                        // so it stays in the roomy leading column.
                        if item.kind.isContainer {
                            childrenSection
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Trailing column — secondary detail.
                    VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                        if !item.kind.isContainer, current.mediaInfo != nil {
                            technicalDetailsSection
                        }
                        if item.kind != .show {
                            castSection
                        }
                    }
                    .frame(width: trailingColumnWidth, alignment: .leading)
                }
                .padding(.horizontal, AetherDesign.Spacing.xl)
                .padding(.top, AetherDesign.Spacing.xl)
                .padding(.bottom, AetherDesign.Spacing.xxl)
            }
        }
    }
    #endif

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
    /// Full-screen artwork background for the whole Detail page (#290): the
    /// title's backdrop crisp, or its poster blurred into atmosphere when no
    /// backdrop exists. `current` (not `activeItem`) so it tracks source
    /// switches + hydration.
    private var cinematicDetailBackground: some View {
        let backdrop = current.backdropURL(heroBackdropTier)
        return CinematicArtworkBackground(
            url: backdrop ?? current.posterURL(.detail),
            blurRadius: backdrop != nil ? 0 : 40,
            maxPixel: heroBackdropTier.maxPixel
        )
    }

    private var heroBackdropTier: ArtworkTier {
        #if os(tvOS) || os(visionOS)
        return .backdropLarge
        #else
        return .backdrop
        #endif
    }

    /// Reserved hero-band height in `scrollContent` (the `Color.clear` spacer
    /// the title sits below). On regular width it matches the backdrop; on
    /// iPhone, **shows** get a shorter band so the Continue Watching / Next Up
    /// card and Seasons rise toward the top instead of sitting below the fold
    /// (#337). Movies keep the taller cinematic band.
    private var compactHeroBandHeight: CGFloat {
        if hSizeClass == .regular { return backdropMaxHeight }
        return isShow ? 150 : 220
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
            // Each focusable section that neighbours the More Like This / Cast
            // rails below is a full-width focus column, so Up/Down from any rail
            // card lands cleanly above/below at any scroll offset (#359).
            if availableSources.count > 1 {
                sourceSwitcher
                    .aetherDetailColumn()
            }
            #if !os(tvOS)
            if current.mediaInfo != nil {
                technicalDetailsSection
                    .aetherDetailColumn()
            }
            #endif
            relatedRail
            if current.streamURL != nil {
                playbackSection
                    .aetherDetailColumn()
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
            // The full-screen cinematic background (#290) is the hero artwork
            // now — reserve the same height so the title sits over the lower
            // part of that art instead of stacking a second backdrop banner.
            Color.clear.frame(height: compactHeroHeight(size))

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
            // Hero artwork comes from the full-screen cinematic background (#290);
            // reserve the stage height so the embedded actions sit at the bottom
            // of it, over the art, with no second backdrop image.
            Color.clear
                .frame(width: size.width, height: movieHeroHeight(size))

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
        // tvOS: the hero is a full-width focus section so Up from the first
        // below-hero rail (More Like This) reaches the action row at ANY scroll
        // offset — section-to-section focus uses the section *frame* (full width
        // here), not the actions' capped geometry. This covers the single-source
        // movie with no Available Sources, where the hero is the rail's nearest
        // focusable neighbour (#359). No-op off tvOS → the visionOS hero (and its
        // first-use hint, #355) is untouched.
        .aetherDetailFocusSection()
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
                                    isWatched: rel.isWatched,
                                    netflixLogoURL: appSession.watchAvailability.netflixLogoURL(for: rel)
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
                // Same watched treatment as the poster cards — dimming + WATCHED
                // wordmark + gold ribbon (compact for the small still) (#280).
                .watchedArtwork(episode.isWatched, display: watchedDisplay, compact: true)
                .clipShape(RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous))
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
        if let date = episode.releaseDate { return DetailFormatting.airDate(date, locale: locale) }
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
        if let date = episode.releaseDate { parts.append(DetailFormatting.airDate(date, locale: locale)) }
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
                // Unified action cluster (#382): the show's primary action is a
                // single "▶ S1E1 · Pilot" pill that plays the on-deck episode,
                // beside the borderless Favorite icon — collapsing the old "NEXT
                // UP" card (a navigate-to-episode tile) into one Infuse-style
                // row. Full-width focus section so Up from ANY season card lands
                // here — section-to-section focus uses the section frames, not
                // the card geometry, so it works from Season 1 through Season N
                // (#266 feedback). Pairs with the seasons rail's own focus section.
                showActionCluster
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
                // Full-width focus column so Down from any More Like This card
                // lands here at any scroll offset — the section above the rail is
                // the seasons rail (already full-width); below is this (#359).
                if availableSources.count > 1 {
                    sourceSwitcher
                        .aetherDetailColumn()
                }
            }
        }
    }

    /// The show's unified action cluster (#382): a primary pill that plays the
    /// on-deck episode (newest in-progress, else the one after the last watched —
    /// `OnDeck.next`), beside the borderless Favorite icon when the source
    /// supports it. Replaces the old "NEXT UP" navigate-to-episode card. The pill
    /// routes through `EpisodeAutoplayRoute` so one tap plays while still reusing
    /// the episode's own, well-tested Detail playback path — `NavigationLink`,
    /// not a `Button`, so it's focusable on tvOS and reachable by the remote.
    /// Hidden until the on-deck episode resolves.
    @ViewBuilder
    private var showActionCluster: some View {
        if let episode = nextUpEpisode {
            HStack(spacing: AetherDesign.Spacing.m) {
                NavigationLink(value: EpisodeAutoplayRoute(item: episode)) {
                    AetherButtonLabel(
                        title: showPlayLabel(for: episode),
                        systemImage: "play.fill",
                        role: .primary
                    )
                }
                .buttonStyle(.plain)
                if source?.supportsFavorites == true {
                    AetherIconButton(
                        systemImage: isFavorite ? "heart.fill" : "heart",
                        accessibilityLabel: isFavorite ? "Remove from favorites" : "Add to favorites",
                        isActive: isFavorite
                    ) {
                        Task { await toggleFavorite() }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// The on-deck episode pill label: "S1E1 · Pilot" to start fresh, or
    /// "S2E4 · Continue" when that episode is already in progress (#382). The
    /// episode code / title aren't translatable; "Continue" is resolved here so
    /// it localizes even though it's interpolated into the string.
    private func showPlayLabel(for episode: MediaItem) -> String {
        if nextUpResume != nil, let s = episode.seasonNumber, let e = episode.episodeNumber {
            return "S\(s)E\(e) · " + String(localized: "Continue")
        }
        return DetailFormatting.episodeLabel(episode)
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

    /// Resolve an episode's parent season + show from `parentID` so the detail
    /// can offer upward navigation (#282). Server episodes nest episode → season
    /// → show; flat sources (Local / SMB) nest episode → show directly, so the
    /// immediate parent may already be the show.
    private func loadEpisodeParents() async {
        parentSeason = nil
        parentShow = nil
        guard item.kind == .episode, let source,
              let parentID = activeItem.parentID,
              let parent = try? await source.item(for: parentID) else { return }
        switch parent.kind {
        case .season:
            parentSeason = parent
            if let showID = parent.parentID, let show = try? await source.item(for: showID) {
                parentShow = show
            }
        case .show:
            parentShow = parent
        default:
            break
        }
    }

    /// Episode-detail upward navigation: "Season N" and/or the series. Hidden
    /// when neither parent resolved (#282).
    @ViewBuilder
    private var episodeParentNavigation: some View {
        if item.kind == .episode, parentSeason != nil || parentShow != nil {
            HStack(spacing: AetherDesign.Spacing.m) {
                if let parentSeason {
                    NavigationLink(value: parentSeason) {
                        parentNavLabel(DetailFormatting.seasonLabel(parentSeason), systemImage: "rectangle.stack")
                    }
                    .buttonStyle(.plain)
                }
                if let parentShow {
                    NavigationLink(value: parentShow) {
                        parentNavLabel(parentShow.title, systemImage: "tv")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func parentNavLabel(_ text: String, systemImage: String) -> some View {
        HStack(spacing: AetherDesign.Spacing.xs) {
            Image(systemName: systemImage)
            Text(text).lineLimit(1)
        }
        .font(AetherDesign.Typography.metadata)
        .foregroundStyle(AetherDesign.Palette.textPrimary)
        .padding(.horizontal, AetherDesign.Spacing.m)
        .padding(.vertical, AetherDesign.Spacing.s)
        .background(AetherDesign.Palette.surfaceElevated, in: Capsule())
        .premiumFocus()
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
            if let date = activeItem.releaseDate { parts.append(DetailFormatting.airDate(date, locale: locale)) }
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
                // The rail is its own focus section so that on tvOS Up/Down from
                // any (now-tappable) cast card lands cleanly on the one element
                // above/below — no focus trap (#341, the constraint behind #249).
                .aetherDetailFocusSection()
            }
        }
    }

    /// One Cast & Crew card. Tappable → the person's filmography when the source
    /// gave us a queryable id (#341); otherwise a plain, non-interactive card
    /// (so it doesn't trap tvOS focus with a dead destination, per #249).
    @ViewBuilder
    private func castCard(_ member: CastMember) -> some View {
        if let entry = castPersonEntry(member) {
            NavigationLink(value: entry) {
                CastCardContent(member: member, size: castPhotoSize)
            }
            .buttonStyle(.plain)
        } else {
            CastCardContent(member: member, size: castPhotoSize)
        }
    }

    /// Build a `PersonEntry` (the value the universal person-grid destination
    /// takes) from a cast member, scoped to the shown item's source. `nil` when
    /// the source didn't supply a queryable person id.
    private func castPersonEntry(_ member: CastMember) -> PersonEntry? {
        guard let personID = member.personID, !personID.isEmpty else { return nil }
        let person = MediaPerson(
            id: MediaID(source: current.id.source, rawValue: personID),
            kind: .actor,
            name: member.name
        )
        return PersonEntry(name: member.name, kind: .actor, members: [person])
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

    // MARK: - Source switcher (compact, #380)

    /// Compact replacement for the old full-width "Available Sources" section
    /// (#380): a labelled `Menu` pill (e.g. `Plex ▾`) showing the active source.
    /// The menu lists every source — the active one checked, the preferred one
    /// tagged, the quality noted — and tapping a playable source re-points the
    /// whole screen (`selectSource`). Deliberately a *labelled* control rather
    /// than a cryptic tertiary icon, so it doesn't reintroduce the width-shifting
    /// blue glyph removed from the action row in #356. Only rendered when
    /// `availableSources.count > 1` (call-site guard).
    private var sourceSwitcher: some View {
        Menu {
            ForEach(availableSources) { src in
                Button {
                    selectSource(src)
                } label: {
                    sourceMenuRow(src)
                }
                .disabled(!src.playable)
            }
        } label: {
            sourceSwitcherLabel
        }
        // Strip the Menu's default accent button chrome so the pill reads as a
        // neutral secondary control (matches `downloadIconButton`, #356).
        .buttonStyle(.plain)
        .accessibilityLabel("Source")
    }

    /// The inline pill: a drive glyph, the active source's name, and a chevron.
    private var sourceSwitcherLabel: some View {
        let active = availableSources.first { $0.item.id == activeItem.id }
        return HStack(spacing: AetherDesign.Spacing.xs) {
            Image(systemName: "externaldrive")
                .font(.caption)
            Text(verbatim: active?.serverName ?? active?.kind.displayName ?? "")
                .font(AetherDesign.Typography.caption)
            Image(systemName: "chevron.down")
                .font(.caption2)
        }
        .foregroundStyle(AetherDesign.Palette.textSecondary)
        .padding(.horizontal, AetherDesign.Spacing.m)
        .padding(.vertical, AetherDesign.Spacing.xs)
        .background(AetherDesign.Materials.card, in: Capsule())
        .overlay(Capsule().strokeBorder(AetherDesign.Palette.separator, lineWidth: 1))
        .contentShape(Capsule())
        .premiumFocus()
    }

    /// One menu entry: a checkmark on the active source (otherwise the kind
    /// glyph), the server name, its quality if known, and a "Preferred" tag on
    /// the default source.
    @ViewBuilder
    private func sourceMenuRow(_ src: UnifiedSource) -> some View {
        let isActive = src.item.id == activeItem.id
        let isPreferred = src.item.id == item.id
        let name = src.serverName ?? src.kind.displayName
        let glyph = src.kind == .offline ? "arrow.down.circle" : "externaldrive"
        Label {
            sourceMenuTitle(name: name, quality: src.quality, isPreferred: isPreferred)
        } icon: {
            Image(systemName: isActive ? "checkmark" : glyph)
        }
    }

    /// `<server> · <quality> · Preferred` — the dynamic parts are verbatim
    /// (server name / resolution are data), only "Preferred" is localized, so the
    /// pieces are composed with `Text` concatenation to keep that segment
    /// translatable.
    @ViewBuilder
    private func sourceMenuTitle(name: String, quality: String?, isPreferred: Bool) -> some View {
        let base = quality.map { Text(verbatim: "\(name) · \($0)") } ?? Text(verbatim: name)
        if isPreferred {
            base + Text(verbatim: " · ") + Text("Preferred")
        } else {
            base
        }
    }

    /// Switch the screen to a different source. Resets the per-source state
    /// (hydration / playback / resume / children) so `.task(id:)` reloads it for
    /// the chosen server. Clearing `overrideItem` (selecting the preferred
    /// source) returns to the navigated item.
    private func selectSource(_ src: UnifiedSource) {
        guard src.playable, src.item.id != activeItem.id else { return }
        configuredItem = nil
        playbackItem = nil
        advancedItem = nil   // a manual source switch supersedes any auto-advance
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
            // Compact iPhone can't fit the whole cluster (Resume pill + Restart +
            // up to ~4 tertiary icons) on one line, and the old two-row layout is
            // gone — so let it scroll horizontally there instead of clipping. iPad
            // / tvOS / visionOS have the width, so they keep a plain row (no
            // scroll → no change to remote focus traversal on tvOS).
            #if os(iOS)
            if hSizeClass == .compact {
                ScrollView(.horizontal, showsIndicators: false) { actionCluster }
            } else {
                actionCluster
            }
            #else
            actionCluster
            #endif
        } else if isNetflixOnly {
            netflixOnlyActions
        } else {
            unavailableState
        }
    }

    /// The unified action cluster (#382, Infuse-style): the primary Resume/Play
    /// pill, Restart demoted to a borderless icon right after it, then the
    /// tertiary icons — all at one vertical level instead of a pill row stacked
    /// over a separate icon row. Play/Resume stays first so the tvOS remote lands
    /// on it (not the watched toggle), and every button is reachable left→right
    /// by the Siri Remote. Left-aligned by the parent column (no trailing Spacer,
    /// which would misbehave inside the compact-width horizontal ScrollView).
    private var actionCluster: some View {
        HStack(spacing: AetherDesign.Spacing.m) {
            if resume != nil { resumeButton } else { playButton }
            if resume != nil { restartIconButton }
            #if os(visionOS)
            watchInCinemaButton
            #endif
            compactActionButtons
        }
    }

    /// Tertiary actions as borderless icon buttons (#382) — Download · Watched ·
    /// Favorite · Details · etc. Returned as bare buttons (no enclosing HStack)
    /// so they drop straight into `actionRow`'s single horizontal cluster; each
    /// is a focusable `Button` / `Menu`, so the whole row stays reachable
    /// left/right by the tvOS remote.
    @ViewBuilder
    private var compactActionButtons: some View {
        if shouldShowDownloadControl {
            downloadIconButton
        }
        if source != nil {
            AetherIconButton(
                systemImage: isWatched ? "eye.fill" : "eye",
                accessibilityLabel: isWatched ? "Mark as unwatched" : "Mark as watched",
                isActive: isWatched
            ) {
                Task { await toggleWatched() }
            }
        }
        if source?.supportsFavorites == true {
            AetherIconButton(
                systemImage: isFavorite ? "heart.fill" : "heart",
                accessibilityLabel: isFavorite ? "Remove from favorites" : "Add to favorites",
                isActive: isFavorite
            ) {
                Task { await toggleFavorite() }
            }
        }
        // Source switching is not a tertiary icon here: it lived as a cryptic,
        // width-shifting, blue-tinted glyph that collided with "blue = active"
        // (#356). It now has a labelled home in the body — the compact
        // `sourceSwitcher` pill (#380), shown when count > 1.
        if current.mediaInfo != nil {
            AetherIconButton(systemImage: "info.circle", accessibilityLabel: "Technical details") {
                presentedSelector = .technicalDetails
            }
        }
        // "Also on Netflix" (#360): a secondary link-out for an owned title
        // that's also on Netflix. Launch-capable platforms only (not tvOS).
        if ownedNetflixProvider != nil && NetflixLauncher.canLaunch {
            AetherIconButton(systemImage: "play.tv", accessibilityLabel: "Play on Netflix") {
                playOnNetflix()
            }
        }
        #if !os(tvOS)
        // Edit metadata — local items only (movies / episodes, not show
        // containers, whose id is "show:<series>" rather than an item id).
        if activeItem.id.source == .local && !activeItem.kind.isContainer {
            AetherIconButton(systemImage: "pencil", accessibilityLabel: "Edit metadata") {
                presentedSelector = .editMetadata
            }
        }
        // SMB items carry no metadata — let the user correct the title/year
        // so a mis-named file matches a TMDb poster (#213). Movies/episodes
        // only (not show containers, whose id is "show:<series>").
        if isSMBSource(activeItem.id.source) && !activeItem.kind.isContainer {
            AetherIconButton(systemImage: "pencil", accessibilityLabel: "Edit title and year") {
                presentedSelector = .smbEditMetadata
            }
        }
        #endif
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
        // Strip the Menu's default accent-tinted button chrome so the icon reads
        // identically to the plain `AetherIconButton`s in the row — blue is then
        // driven only by `isActive` (downloaded), never by the menu decoration,
        // keeping "blue = primary/active" consistent (#356 follow-up).
        .buttonStyle(.plain)
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
                // SMB is a raw file share — no server transcode, so skip the
                // quality picker and download the original file directly.
                if isSMBSource(activeItem.id.source) {
                    Task { await startDownload(quality: .original) }
                } else {
                    presentedSelector = .downloadQuality
                }
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
        let next = !isWatched
        // Marking an **in-progress** title watched throws away its resume point.
        // Confirm first so a single tap can't silently wipe progress; un-marking
        // or marking a not-started title needs no confirmation.
        if next, resume != nil {
            confirmMarkWatched = true
            return
        }
        await setWatched(next)
    }

    private func setWatched(_ next: Bool) async {
        watchedOverride = next   // optimistic
        // Sync across every source that has this title, not just `source` —
        // e.g. a movie on both Plex and Jellyfin flips on both.
        await appSession.markWatchedEverywhere(activeItem, watched: next)
        // Watched ends "in progress": drop the resume point so the title leaves
        // Continue Watching and never offers "Resume" a second before the end.
        if next {
            await resumeStore.clear(for: activeItem.id)
            resume = nil
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

    /// Restart — demoted from a text pill to a borderless icon button right
    /// after the primary pill (#382), so the cluster reads as one row. The pill
    /// label already carries the resume time, so "from the beginning" only needs
    /// an icon. Disabled while playback is preparing, like the primary buttons.
    @ViewBuilder
    private var restartIconButton: some View {
        AetherIconButton(
            systemImage: "backward.end.fill",
            accessibilityLabel: "Play from beginning"
        ) {
            guard !isPreparingPlayback else { return }
            Task { await presentPlayer(fromStart: true) }
        }
        .opacity(isPreparingPlayback ? 0.4 : 1)
    }

    private var unavailableState: some View {
        AetherErrorState(
            glyph: "play.slash",
            title: "Playback unavailable",
            message: "This title isn't streamable yet. If it's a format Plex can't direct-play, transcode support lands in a future update."
        )
        .padding(.top, -AetherDesign.Spacing.xxl)
    }

    // MARK: - Netflix availability (#360)

    /// `true` when this is a Netflix-only title (no library source backs it) —
    /// its primary action is "Play on Netflix", not in-app playback.
    private var isNetflixOnly: Bool {
        if case .external = item.id.source { return true }
        return false
    }

    /// The Netflix provider for an **owned** title (badge + secondary action),
    /// or nil. External-only titles are handled by `isNetflixOnly` instead.
    private var ownedNetflixProvider: ExternalProvider? {
        guard !isNetflixOnly else { return nil }
        return appSession.watchAvailability.netflix(forTMDb: current.guids.tmdb, isShow: current.kind == .show)
    }

    /// Open the title on Netflix (app or web). No-op on tvOS (caller hides it).
    private func playOnNetflix() {
        guard let url = NetflixLauncher.searchURL(title: current.title) else { return }
        openURL(url)
    }

    /// Primary actions for a Netflix-only title: "Play on Netflix" where it can
    /// launch (iOS/iPadOS/macOS/visionOS), or an informational note on tvOS.
    @ViewBuilder
    private var netflixOnlyActions: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.s) {
            if NetflixLauncher.canLaunch {
                AetherButton("Play on Netflix", systemImage: "play.fill", role: .primary) {
                    playOnNetflix()
                }
            } else {
                Label("Available on Netflix", systemImage: "tv")
                    .font(AetherDesign.Typography.body)
                    .foregroundStyle(AetherDesign.Palette.textSecondary)
            }
            Text("Aether links out to Netflix — it doesn't stream it here.")
                .font(AetherDesign.Typography.caption)
                .foregroundStyle(AetherDesign.Palette.textTertiary)
        }
        // On tvOS a Netflix-only detail has no launch button (`canLaunch` is
        // false there), so this block is pure text — and a pushed screen with
        // NOTHING focusable traps the user: the system reads Back/Menu as
        // "exit app" instead of "pop" (#377). Make the block self-focus when
        // there's no button, mirroring AetherEmptyState/AetherErrorState. A
        // no-op elsewhere, where `canLaunch` is true and the button takes focus.
        .focusable(!NetflixLauncher.canLaunch)
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
        case .smbEditMetadata:
            SMBMetadataEditSheet(
                itemID: activeItem.id,
                currentTitle: current.title,
                currentYear: current.year
            ) {
                presentedSelector = nil
                localEditToken = UUID()   // re-hydrate Detail with the corrected match
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
        /// VLCKit media options (SMB credentials + caching) — empty for local files.
        var options: [String] = []
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
            // SMB needs its credentials passed to VLCKit as media options (the
            // URL stays credential-free) — empty for local files (#214).
            let options = (source as? SMBMediaSource)?.vlcMediaOptions ?? []
            vlcPlayback = VLCPlayback(url: url, options: options)
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

/// Shared layout metrics for the Detail screen.
private enum DetailLayout {
    /// Readable content-column width for the capped body sections (synopsis,
    /// Available Sources, Playback, Technical Details). Named so the magic number
    /// lives in one place and the focus-column helper can pair the visual cap
    /// with a full-width focus frame.
    static let contentWidth: CGFloat = 720
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

    /// `aetherDetailFocusSection()` applied only when `condition` holds — so a
    /// section can opt out of being its own focus group where that would shadow
    /// a more specific inner section (e.g. the seasons layout's Next-Up anchor,
    /// #266). No-op off tvOS.
    @ViewBuilder
    func aetherDetailFocusSection(when condition: Bool) -> some View {
        if condition {
            self.aetherDetailFocusSection()
        } else {
            self
        }
    }

    /// A width-capped Detail body section whose **focus-section frame spans the
    /// full width** while the content stays visually capped + leading-aligned.
    ///
    /// On tvOS, section-to-section (Up/Down) focus is resolved by the section
    /// *frames*, not the focused card's geometry — so a horizontal rail's vertical
    /// neighbour must be full-width to remain a focus target at *any* horizontal
    /// scroll offset. A neighbour capped to `contentWidth` stops overlapping a
    /// card once the rail scrolls past it, and focus gets trapped in the rail
    /// (#359). This generalises the #266 seasons fix (a full-width Next-Up anchor)
    /// to every Detail rail. Visual layout is unchanged on every platform.
    func aetherDetailColumn(maxWidth: CGFloat = DetailLayout.contentWidth) -> some View {
        self
            .frame(maxWidth: maxWidth, alignment: .leading)   // readable visual cap
            .frame(maxWidth: .infinity, alignment: .leading)  // full-width focus frame
            .aetherDetailFocusSection()
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
