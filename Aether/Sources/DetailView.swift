import SwiftUI
import os
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
    // `internal` (not `private`): read by the seasons/episodes cluster in
    // DetailView+SeasonsEpisodes.swift (#241 inc 4 file split).
    @State var viewModel: DetailViewModel

    // MARK: - Presentation state (stays in the view)

    /// Drives the "mark an in-progress title watched?" confirmation — marking
    /// watched discards the resume point, so it asks first.
    @State var confirmMarkWatched = false
    @State private var isPlayerPresented = false
    /// Set when a local file needs the VLCKit engine (mkv etc.) instead of AVKit.
    @State private var vlcPlayback: VLCPlayback?
    /// Set when a local MKV is played through the AVFoundation remux path (#476)
    /// instead of VLCKit.
    @State private var remuxPlayback: RemuxPlayback?
    /// #476: route a local MKV through the AVFoundation remux shim (AVPlayer)
    /// instead of VLCKit when the muxer can fully package it — H.264/HEVC video
    /// + AAC audio, B-frames handled, validated end-to-end (plays on AVPlayer).
    /// `RemuxedLocalAsset` returns nil for anything else (E-AC-3/DTS/exotic) so
    /// those fall back to VLCKit.
    /// **On by default** (#476 P4/P6): the progressive-MP4 remux exposes audio +
    /// SRT-subtitle media-selection groups and AVPlayer seeks it (full sample
    /// tables). Verified on-device — playback, seeking, and the subtitle track
    /// AVFoundation surfaces.
    @AppStorage("player.remuxLocalMKV") private var remuxLocalMKVEnabled = true
    #if os(visionOS)
    /// visionOS: drives the "Continue or Start Over" prompt before entering
    /// Cinema Mode when a resume point exists.
    @State var showCinemaResumePrompt = false
    #endif
    /// tvOS: which season card has focus, so the Show page previews it while
    /// browsing (#266 — Focus = Preview, Select = Open).
    // `internal` (not `private`): the seasons/episodes rails that read these —
    // and bind `$focusedSeasonID` / `$focusedEpisodeID` — live in
    // DetailView+SeasonsEpisodes.swift (#241 inc 4 file split).
    @FocusState var focusedSeasonID: MediaID?
    /// Last-focused season, kept so the preview stays put when focus leaves the
    /// rail (defaults to the first season).
    @State var previewSeasonID: MediaID?
    /// tvOS: which episode still has focus — the rail previews it below
    /// (synopsis, runtime, air date, resume), same Focus = Preview model (#267).
    @FocusState var focusedEpisodeID: MediaID?
    /// Last-focused episode, kept so the preview stays put when focus leaves.
    @State var previewEpisodeID: MediaID?
    /// Which compact selector sheet is currently presented on Detail. `nil`
    /// = nothing open; tapping a disclosure row sets one. iOS / iPadOS uses
    /// `.presentationDetents([.medium])` so the picker takes about half the
    /// screen and the Detail backdrop is still visible behind.
    @State var presentedSelector: PlaybackSelector?
    #if os(tvOS)
    /// On tvOS the SMB metadata editor presents full-screen — a big, couch-
    /// readable match gallery, with no tab bar bleeding through behind a
    /// centered card. Every other selector stays in the shared sheet. These two
    /// bindings split the single `presentedSelector` across the two
    /// presentations so only one is ever active.
    var nonSMBSelector: Binding<PlaybackSelector?> {
        Binding(
            get: { presentedSelector == .smbEditMetadata ? nil : presentedSelector },
            set: { presentedSelector = $0 }
        )
    }
    var smbSelector: Binding<PlaybackSelector?> {
        Binding(
            get: { presentedSelector == .smbEditMetadata ? presentedSelector : nil },
            set: { if $0 == nil { presentedSelector = nil } }
        )
    }
    #endif
    // Set when the local metadata editor closes, to re-point the screen at the
    // edited item so its title / poster / overview repaint (#211). Seeded nil so
    // the re-hydrate task below is a no-op on first appear (no double fetch).
    @State var localEditToken: UUID?
    /// Technical Details starts tucked — rich info without cluttering the page.
    @State var technicalDetailsExpanded = false
    /// Guards the one-shot autoplay (#382) so re-running the load task (source
    /// switch, scene re-activation) can't relaunch the player after the user has
    /// already dismissed it.
    @State private var didAutoplay = false
    /// TMDb `vote_average` fetched lazily for Plex/Jellyfin items — `nil` until
    /// the fetch completes or when the item has no TMDb ID / no API key.
    @State var tmdbRating: Double?

    // MARK: - DetailViewModel forwarders (#241 inc 1)
    // Same-named computed forwarders so the section builders and load / mutate
    // funcs compile untouched while the data state lives in the VM. `@Observable`
    // tracking works through these because the `viewModel.x` read happens during
    // body evaluation. Inlined away as funcs migrate in later increments.

    var resume: ResumePoint? {
        get { viewModel.resume }
        nonmutating set { viewModel.resume = newValue }
    }
    var overrideItem: MediaItem? {
        get { viewModel.overrideItem }
        nonmutating set { viewModel.overrideItem = newValue }
    }
    private var advancedItem: MediaItem? {
        get { viewModel.advancedItem }
        nonmutating set { viewModel.advancedItem = newValue }
    }
    var watchedOverride: Bool? {
        get { viewModel.watchedOverride }
        nonmutating set { viewModel.watchedOverride = newValue }
    }
    private var playbackItem: MediaItem? {
        get { viewModel.playbackItem }
        nonmutating set { viewModel.playbackItem = newValue }
    }
    private var playbackStartAt: Double? {
        get { viewModel.playbackStartAt }
        nonmutating set { viewModel.playbackStartAt = newValue }
    }
    var isPreparingPlayback: Bool {
        get { viewModel.isPreparingPlayback }
        nonmutating set { viewModel.isPreparingPlayback = newValue }
    }
    private var launchingInCinema: Bool {
        get { viewModel.launchingInCinema }
        nonmutating set { viewModel.launchingInCinema = newValue }
    }
    var children: [MediaItem] {
        get { viewModel.children }
        nonmutating set { viewModel.children = newValue }
    }
    var isLoadingChildren: Bool {
        get { viewModel.isLoadingChildren }
        nonmutating set { viewModel.isLoadingChildren = newValue }
    }
    var related: [MediaItem] {
        get { viewModel.related }
        nonmutating set { viewModel.related = newValue }
    }
    var seasonEpisodes: [MediaItem] {
        get { viewModel.seasonEpisodes }
        nonmutating set { viewModel.seasonEpisodes = newValue }
    }
    var isLoadingEpisodes: Bool {
        get { viewModel.isLoadingEpisodes }
        nonmutating set { viewModel.isLoadingEpisodes = newValue }
    }
    var nextUpEpisode: MediaItem? {
        get { viewModel.nextUpEpisode }
        nonmutating set { viewModel.nextUpEpisode = newValue }
    }
    var nextUpResume: ResumePoint? {
        get { viewModel.nextUpResume }
        nonmutating set { viewModel.nextUpResume = newValue }
    }
    var episodeResume: [MediaID: ResumePoint] {
        get { viewModel.episodeResume }
        nonmutating set { viewModel.episodeResume = newValue }
    }
    var fallbackCast: [CastMember] {
        get { viewModel.fallbackCast }
        nonmutating set { viewModel.fallbackCast = newValue }
    }
    var parentSeason: MediaItem? {
        get { viewModel.parentSeason }
        nonmutating set { viewModel.parentSeason = newValue }
    }
    var parentShow: MediaItem? {
        get { viewModel.parentShow }
        nonmutating set { viewModel.parentShow = newValue }
    }
    var heroLogo: AetherPlatformImage? {
        get { viewModel.heroLogo }
        nonmutating set { viewModel.heroLogo = newValue }
    }
    var configuredItem: MediaItem? {
        get { viewModel.configuredItem }
        nonmutating set { viewModel.configuredItem = newValue }
    }
    var isEnqueuingDownload: Bool {
        get { viewModel.isEnqueuingDownload }
        nonmutating set { viewModel.isEnqueuingDownload = newValue }
    }
    /// The app session — used to mark watched/unwatched on **every** connected
    /// source that has the title (not just the one Detail is acting on), so a
    /// movie on both Plex and Jellyfin stays in sync (#232 follow-up).
    @Environment(AppSession.self) var appSession
    /// For the "Play on Netflix" link-out (#360).
    @Environment(\.openURL) var openURL
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    /// Drives the backdrop layout: compact (iPhone) → full-width 16:9; regular
    /// (iPad / tvOS / visionOS) → edge-to-edge fill at a fixed height.
    @Environment(\.horizontalSizeClass) var hSizeClass
    @Environment(\.dismiss) var dismiss
    /// App language locale (#320) — release dates format in this locale.
    @Environment(\.locale) var locale
    /// Watched dimming + label preference, so episode-row stills match the
    /// poster cards' watched treatment (#280 follow-up).
    @Environment(\.watchedDisplay) var watchedDisplay
    #if os(visionOS)
    /// Cinema Mode state — drives the "Watch in Cinema" entry. Injected at the
    /// app root; always present inside the windowed view tree on visionOS.
    @Environment(CinemaManager.self) var cinema
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
    // `internal`: playbackSelectorSheet(for:) (DetailView+PlaybackConfig.swift) takes this (#241 inc 6).
    enum PlaybackSelector: Identifiable {
        case audio, subtitles, quality, downloadQuality, technicalDetails
        case smbEditMetadata
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
            case .smbEditMetadata: return "smbEditMetadata"
            #if !os(tvOS)
            case .editMetadata: return "editMetadata"
            #endif
            }
        }
    }

    /// The source the screen is currently acting on (#241: body lives in the VM,
    /// forwarded here so the section builders read it unchanged).
    var activeItem: MediaItem { viewModel.activeItem }

    /// Whether a source id is an SMB share (drives the title/year editor, #213).
    func isSMBSource(_ source: MediaSourceID) -> Bool {
        if case .smb = source { return true }
        return false
    }

    /// The item reflecting hydration + the user's track / quality selections.
    var current: MediaItem { viewModel.current }

    /// The connector for the shown item (#241: derived in the VM).
    var source: (any MediaSource)? { viewModel.source }

    /// Download status for this item (#241: derived in the VM).
    var downloadStatus: DownloadStatus { viewModel.downloadStatus }

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
        // Keyed on the active item: re-runs when the user switches source via
        // "Available Sources", re-hydrating + reloading resume/children for the
        // newly-selected server. The `.task` stays on the view (SwiftUI cancels
        // it on id change / disappear); the VM methods are awaited inside it so
        // cooperative cancellation flows through unchanged (#241 inc 2).
        .task(id: activeItem.id) {
            await viewModel.runMainPipeline()
            // One-shot autoplay (#382): the show "Play S1E1" pill routes here
            // with `autoplay` set. Hydration is done, so launch the player now —
            // `fromStart: false` resumes from the saved point when the on-deck
            // episode is in progress, else starts from the top. The launcher is
            // Environment-coupled so it stays view-side. Guarded so a later task
            // re-run (source switch / re-activation) can't relaunch.
            if autoplay, !didAutoplay {
                didAutoplay = true
                await presentPlayer(fromStart: false)
            }
            await viewModel.loadRelated()
        }
        // Re-point the screen after the local metadata editor closes (#211): the
        // item id is unchanged, so the main task won't re-run. The token gate
        // stays here (the view owns the token); the VM does the fetch + decides.
        // On a kind change (movie↔episode) the item now lives under a different
        // library grouping, so pop back rather than render a contradictory screen.
        .task(id: localEditToken) {
            guard localEditToken != nil else { return }
            if await viewModel.refreshAfterLocalEdit() == .kindChanged {
                dismiss()
            }
        }
        // clearLogo for the hero — keyed on the minted URL so it re-fires when
        // hydration fills `configuredItem` (Plex logos arrive on the detail
        // endpoint, not the library list) and when the user switches source.
        .task(id: current.logoURL()) {
            await viewModel.loadHeroLogo()
        }
        // TMDb rating — fetched lazily for Plex/Jellyfin items that carry a
        // TMDb GUID but whose server community rating may differ. Uses the
        // already-populated `tmdbRating` when the Local Library set it.
        .task(id: item.id) {
            if let preloaded = item.tmdbRating {
                tmdbRating = preloaded
                return
            }
            guard appSession.isTMDbConfigured,
                  let rawID = item.guids.tmdb,
                  let tmdbID = Int(rawID) else { return }
            let type: TMDbClient.MediaType = item.kind == .show ? .tv : .movie
            let meta = await TMDbClient(apiKey: appSession.tmdbAPIKey, api: appSession.api)
                .details(tmdbID: tmdbID, type: type)
            tmdbRating = meta?.rating
        }
        .animation(reduceMotion ? nil : AetherDesign.Motion.hero, value: isPlayerPresented)
        #if os(tvOS)
        // SMB editor → full-screen cover (big gallery, no tab-bar bleed); the
        // rest stays in the shared sheet. Split via the two derived bindings.
        .sheet(item: nonSMBSelector) { selector in
            playbackSelectorSheet(for: selector)
        }
        .fullScreenCover(item: smbSelector) { selector in
            playbackSelectorSheet(for: selector)
        }
        #else
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
        #endif
        .fullScreenCover(item: $vlcPlayback) { playback in
            // SMB has no pre-play track list, so hand the player the app's default
            // audio/subtitle languages — it applies the matching tracks once VLC
            // parses them ("choose before you watch", driven by Settings).
            VLCPlayerView(
                url: playback.url,
                options: playback.options,
                mediaTitle: current.title,
                preferredAudioLanguage: playbackPreferences?.defaultAudioLanguage,
                preferredSubtitleLanguage: playbackPreferences?.defaultSubtitleLanguage,
                resumeAtSeconds: playback.resumeAt,
                onProgress: { seconds, total in
                    if let id = playback.itemID {
                        Task { await viewModel.recordPlaybackProgress(itemID: id, seconds: seconds, total: total) }
                    }
                }
            ) { vlcPlayback = nil }
                .ignoresSafeArea()
        }
        .fullScreenCover(item: $remuxPlayback) { playback in
            RemuxPlayerView(remuxAsset: playback.asset) { remuxPlayback = nil }
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
            Task { await viewModel.refreshResume() }
        }
        #endif
    }

    // MARK: - Player dismiss

    /// Identifies a file routed to the VLCKit engine (for `.fullScreenCover`).
    private struct VLCPlayback: Identifiable {
        let id = UUID()
        let url: URL
        /// VLCKit media options (SMB credentials + caching) — empty for local files.
        var options: [String] = []
        /// The played item's id (to key its resume point).
        var itemID: MediaID? = nil
        /// Resume position in seconds (nil = from the start).
        var resumeAt: Double? = nil
    }

    /// Identifies a local MKV played through the AVFoundation remux path (#476).
    /// Holds the `RemuxedLocalAsset` so its resource-loader delegate stays alive.
    private struct RemuxPlayback: Identifiable {
        let id = UUID()
        let asset: RemuxedLocalAsset
    }

    func presentPlayer(fromStart: Bool) async {
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
        await viewModel.ensureConfiguredForPlayback()
        playbackItem = current

        // Resume context for the VLCKit path (it has no built-in resume): the
        // played item's id + the saved position (unless the user forced a restart).
        let vlcItemID = current.id
        let vlcResumeAt: Double? = fromStart
            ? nil
            : viewModel.resume.map { Double($0.position.components.seconds) }

        // Prefer a completed local download over any server stream — play the
        // bytes the user already has (works offline, and saves bandwidth even
        // when online). Pick the engine from the *downloaded file's* container,
        // NOT from `current.streamURL`: for an mkv the stream URL is a Plex
        // transcode/HLS URL with no `.mkv` extension, so routing on it would
        // hand the local mkv to AVPlayer (which can't demux it), and the
        // AVPlayer path would then fall through to the server address and fail
        // offline ("Unable to prepare playback"). The local file's own
        // extension routes mkv → VLCKit, mp4/m4v → AVPlayer correctly.
        // `existingLocalURL()` verifies the file is on disk (re-basing a stale
        // absolute path onto the current downloads dir): if it's genuinely gone,
        // fall through to streaming instead of mis-playing.
        if let localURL = downloadStatus.existingLocalURL() {
            if VideoEngineResolver.standard.engine(for: localURL) == .vlc {
                // #476: prefer the AVFoundation remux path for a local MKV whose
                // codecs AVFoundation can decode (H.264/HEVC + AAC) — native
                // transport, PiP, AirPlay, no VLCKit. `RemuxedLocalAsset` returns
                // nil when the file isn't remuxable (DTS, exotic codecs), so we
                // fall through to VLCKit and nothing regresses.
                if remuxLocalMKVEnabled, let remux = RemuxedLocalAsset(fileURL: localURL) {
                    remuxPlayback = RemuxPlayback(asset: remux)
                    return
                }
                // Local file — no SMB credentials / caching options needed.
                vlcPlayback = VLCPlayback(url: localURL, itemID: vlcItemID, resumeAt: vlcResumeAt)
                return
            }
            // `.system` container (mp4/m4v/…): the windowed AVPlayer path's
            // `PlaybackSession` already prefers this local file via
            // `offlinePlayableURL()`, so fall through to it below.
        }

        // Local files AVFoundation can't demux (mkv, …) play through the VLCKit
        // engine instead of the AVKit player. Resume / Cinema stay AVPlayer-only
        // for now (fast-follow on this engine).
        if let rawURL = current.streamURL, VideoEngineResolver.standard.engine(for: rawURL) == .vlc {
            // SMB: route through the localhost HTTP range proxy (#213/#347) so
            // VLCKit / AVPlayer use clean HTTP range requests instead of the
            // slow libsmb2 path (each seek re-established an SMB session).
            // mp4/m4v over SMB will now resolve to .system via the proxy URL's
            // extension and fall through to the AVPlayer path below.
            if rawURL.scheme == "smb", let smbSource = source as? SMBMediaSource {
                if let proxyURL = await smbSource.proxyURL(for: rawURL) {
                    if VideoEngineResolver.standard.engine(for: proxyURL) == .vlc {
                        // SMB mkv / avi / ts → VLCKit over the HTTP range proxy.
                        // (Remux→AVPlayer is local-files-only: a seekable MP4 `moov`
                        // needs a full metadata pass, which over SMB means reading
                        // the whole file — prohibitive for multi-GB rips. VLCKit
                        // demuxes on the fly and seeks via MKV Cues, so it's fast.)
                        vlcPlayback = VLCPlayback(url: proxyURL, itemID: vlcItemID, resumeAt: vlcResumeAt)
                        return
                    }
                    // mp4 / m4v over SMB → AVPlayer via proxy (fast path).
                    playbackStartAt = fromStart ? 0 : nil
                    launchingInCinema = false
                    withAnimation(reduceMotion ? nil : AetherDesign.Motion.hero) {
                        isPlayerPresented = true
                    }
                    return
                }
                // Proxy failed — fall back to direct smb:// with credentials.
                vlcPlayback = VLCPlayback(url: rawURL, options: smbSource.vlcMediaOptions, itemID: vlcItemID, resumeAt: vlcResumeAt)
                return
            }
            // Local files (non-SMB smb-scheme files don't exist, but guard anyway).
            vlcPlayback = VLCPlayback(url: rawURL, itemID: vlcItemID, resumeAt: vlcResumeAt)
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
        Task { await viewModel.refreshResume() }
    }

    #if os(visionOS)
    /// Enter Cinema Mode: present the native player (same `PlayerView` /
    /// `AVPlayerViewController` as windowed playback) **and** ask `CinemaManager`
    /// to open the Dark Theater. The system then docks the fullscreen player
    /// into the immersive space — native controls, native sizing. `nil` startAt
    /// resumes from the saved point, mirroring the Resume button.
    func watchInCinema(fromStart: Bool = false) async {
        guard !isPreparingPlayback else { return }
        isPreparingPlayback = true
        defer { isPreparingPlayback = false }

        await viewModel.ensureConfiguredForPlayback()
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
// `internal` (not `private`): referenced by the focus-column helper + the split-out
// Detail extension files (#241 inc 4–6).
enum DetailLayout {
    /// Readable content-column width for the capped body sections (synopsis,
    /// Available Sources, Playback, Technical Details). Named so the magic number
    /// lives in one place and the focus-column helper can pair the visual cap
    /// with a full-width focus frame.
    static let contentWidth: CGFloat = 720
}

// `internal` (not `private`): the Detail screen is split across DetailView.swift +
// DetailView+{SeasonsEpisodes,Layouts,Hero,Actions,PlaybackConfig}.swift, all using these
// focus helpers. One internal copy beats a private copy per file (#241 inc 4–6).
extension View {
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

    // `seasonCardFocus()` + the `SeasonCardFocus` modifier moved to
    // DetailView+SeasonsEpisodes.swift (#241 inc 4) — the seasons rail was their
    // only user.
}
