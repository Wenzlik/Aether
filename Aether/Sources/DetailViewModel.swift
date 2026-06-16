import SwiftUI
import AetherCore

/// The data / business brain behind `DetailView` (#241).
///
/// Everything that is *server / data* state — what the screen shows, what it has
/// loaded, what the user has selected for playback — lives here so it can be
/// reasoned about (and eventually unit-tested) without a SwiftUI view. The view
/// keeps only *presentation* state (sheet / fullScreenCover presentation, focus,
/// one-shot UI guards) and the Environment-coupled playback launchers.
///
/// Increment 1 of the extraction (see issue #241): this owns the deps + all the
/// former `@State` data fields + the derived identity chain. The load pipeline,
/// mutators, and download actions still live in the view for now and write these
/// fields through same-named forwarders; they migrate in later increments.
@MainActor
@Observable
final class DetailViewModel {
    // MARK: Dependencies (untracked references)

    let item: MediaItem
    /// Every connected source. The connector this screen acts on is derived from
    /// the *shown item's* source (see `source`), so a unified-feed title plays
    /// through the right server even when it isn't the app's active source.
    let connectedSources: [any MediaSource]
    let resumeStore: ResumeStore
    /// `nil` until `AppSession.start()` has booted the downloads pipeline.
    let downloadManager: DownloadManager?
    /// `@MainActor`-bound mirror of the download store, read synchronously in
    /// `body`. `nil` until boot completes.
    let downloads: DownloadObserver?
    /// App-wide playback defaults (Default Quality / Audio / Subtitle Language)
    /// seeded into the pickers. `nil` only in test fixtures or pre-boot paths.
    let playbackPreferences: PlaybackPreferencesStore?
    /// Every source that has this title, sorted by priority — populated only when
    /// Detail is reached from the unified feed. Drives "Available Sources" + the
    /// manual source override. Empty for single-source contexts.
    let availableSources: [UnifiedSource]

    // MARK: Server / data state (was DetailView @State)

    var resume: ResumePoint?
    /// The source the user manually switched to via "Available Sources". `nil`
    /// = use the title's preferred source (the navigated `item`). Everything
    /// playback-related follows `activeItem`, so switching swaps the whole screen
    /// to the chosen server without re-navigating.
    var overrideItem: MediaItem?
    /// Set when Auto-Play-Next advanced the player to a *different* episode in
    /// place, so the screen re-points at the episode actually playing (#315).
    var advancedItem: MediaItem?
    /// Optimistic watched state for the manual toggle, so the UI flips instantly.
    /// `nil` = use the item's own `isWatched`. Reset when the active source changes.
    var watchedOverride: Bool?
    var favoriteOverride: Bool?
    var playbackItem: MediaItem?
    /// Where the presented player should begin. `nil` resumes from the saved
    /// point ("Resume"); `0` forces a restart ("Play From Beginning").
    var playbackStartAt: Double?
    var isPreparingPlayback = false
    /// visionOS: the current player presentation was launched via "Watch in
    /// Cinema" → auto-expand so it docks into the Dark Theater without a tap.
    var launchingInCinema = false
    var children: [MediaItem] = []
    var isLoadingChildren = false
    /// Similar titles for the "More Like This" rail (source recommendations).
    var related: [MediaItem] = []
    /// Series detail only — the season the inline episode list is showing.
    var selectedSeason: MediaItem?
    /// Episodes of `selectedSeason`, shown inline (no navigation into a season).
    var seasonEpisodes: [MediaItem] = []
    var isLoadingEpisodes = false
    /// The series "On Deck" episode — the next one to watch across the *whole*
    /// show. Computed once on load and stays put while the user browses seasons.
    var nextUpEpisode: MediaItem?
    /// Saved resume position for the On Deck episode, when one exists.
    var nextUpResume: ResumePoint?
    /// Resume points for the currently-listed episodes (#260). Keyed by episode id.
    var episodeResume: [MediaID: ResumePoint] = [:]
    /// Season pages rarely carry their own cast — the parent show's cast,
    /// fetched as a fallback so Cast & Crew isn't missing on a season (#267).
    var fallbackCast: [CastMember] = []
    /// Episode detail: the parent season + show, resolved from `parentID` so the
    /// screen offers "Season N" / "<Series>" navigation instead of dead-ending (#282).
    var parentSeason: MediaItem?
    var parentShow: MediaItem?
    /// The title's clearLogo, once loaded — the hero swaps its text title for this
    /// wordmark art. Stays nil (text title) for titles whose source has no logo (#273).
    var heroLogo: AetherPlatformImage?
    /// The item with full metadata (audio + subtitle streams, partID, mediaInfo)
    /// once hydrated, carrying the user's audio / subtitle / quality choices.
    /// Playback decisions happen here on Detail, before the player opens. `nil`
    /// until the detail endpoint resolves; `current` falls back to the list `item`.
    var configuredItem: MediaItem?
    /// True while a Download is being prepared (quality picker → enqueue) so the
    /// button can read "Starting…" and disable.
    var isEnqueuingDownload = false

    // MARK: Derived identity chain

    /// The source the screen is currently acting on — the manually-selected
    /// override (or auto-advanced episode), else the navigated `item`. All
    /// playback-related state derives from this.
    var activeItem: MediaItem { advancedItem ?? overrideItem ?? item }

    /// The item reflecting hydration + the user's track / quality selections.
    var current: MediaItem { configuredItem ?? activeItem }

    /// The connector for the shown item — matched by the item's source id, so
    /// playback / hydration / downloads use the correct server even when the item
    /// came from the unified feed. Falls back to the first connected source.
    var source: (any MediaSource)? {
        connectedSources.first { $0.id == activeItem.id.source } ?? connectedSources.first
    }

    /// Download status for this item. `.notDownloaded` when the pipeline hasn't
    /// booted yet — same surface as "no job recorded" so the UI renders identically.
    var downloadStatus: DownloadStatus {
        downloads?.status(for: activeItem.id) ?? .notDownloaded
    }

    init(
        item: MediaItem,
        connectedSources: [any MediaSource],
        resumeStore: ResumeStore,
        downloadManager: DownloadManager?,
        downloads: DownloadObserver?,
        playbackPreferences: PlaybackPreferencesStore?,
        availableSources: [UnifiedSource]
    ) {
        self.item = item
        self.connectedSources = connectedSources
        self.resumeStore = resumeStore
        self.downloadManager = downloadManager
        self.downloads = downloads
        self.playbackPreferences = playbackPreferences
        self.availableSources = availableSources
    }

    // MARK: - Convenience

    private var isShow: Bool { item.kind == .show }

    /// Whether a source id is an SMB share (drives the title/year editor, #213).
    private func isSMBSource(_ source: MediaSourceID) -> Bool {
        if case .smb = source { return true }
        return false
    }

    // MARK: - Load pipeline (#241 inc 2)

    /// The on-appear / source-switch load (the body of the view's main
    /// `.task(id: activeItem.id)`, minus the one-shot autoplay launch + the
    /// related rail, which run view-side after this so order is preserved).
    func runMainPipeline() async {
        await refreshResume()
        await hydrateForPlayback()
        await loadChildrenIfNeeded()
        await setupSeasonsIfNeeded()
        if item.kind == .season {
            // Season page: its children ARE its episodes — Next Up within the
            // season, and the parent show's cast as a fallback (#267).
            await computeNextUp()
            await loadFallbackCastIfNeeded()
        }
        if item.kind == .episode {
            await loadEpisodeParents()   // #282: Season / Show navigation
        }
    }

    /// More Like This rail (source recommendations). Loaded after the main
    /// pipeline + any autoplay launch, matching the original task order.
    func loadRelated() async {
        related = await source?.related(to: activeItem.id) ?? []
    }

    func refreshResume() async {
        resume = await resumeStore.point(for: activeItem.id)
    }

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
    /// last one finished — computed across ALL seasons.
    func computeNextUp() async {
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
    /// the season page's Cast & Crew isn't empty (#267).
    private func loadFallbackCastIfNeeded() async {
        guard item.kind == .season, current.cast.isEmpty, fallbackCast.isEmpty,
              let source,
              let showID = activeItem.parentID ?? item.parentID,
              let show = try? await source.item(for: showID) else { return }
        fallbackCast = show.cast
    }

    /// Resolve an episode's parent season + show from `parentID` so the detail
    /// can offer upward navigation (#282).
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

    /// Fetch resume points for a set of episodes into `episodeResume` (#260),
    /// merging so previously-loaded seasons keep theirs.
    private func loadEpisodeResumes(_ episodes: [MediaItem]) async {
        var map = episodeResume
        for episode in episodes {
            if let point = await resumeStore.point(for: episode.id) { map[episode.id] = point }
        }
        episodeResume = map
    }

    func loadSeasonEpisodes(_ season: MediaItem) async {
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

    private func hydrateForPlayback() async {
        guard !activeItem.kind.isContainer, let source else { return }
        if let hydrated = try? await source.item(for: activeItem.id) {
            // Don't clobber a pick the user made while this hydrate was in
            // flight (#68) — carry any explicit selections onto the fresh item.
            configuredItem = preservingUserSelections(on: applyingPreferences(to: hydrated))
        }
    }

    /// Seeds the user's app-wide playback defaults onto a freshly hydrated item
    /// (audio/subtitle language + default quality), via
    /// `PlaybackPreferencesStore.applied(to:)` so every player entry point shares
    /// it (#68). Internal — the view-side launchers call it during their fallback
    /// hydrate.
    func applyingPreferences(to hydrated: MediaItem) -> MediaItem {
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

    /// The hero clearLogo, keyed (view-side) on `current.logoURL()` so it
    /// re-fires when hydration fills `configuredItem` or the source switches.
    func loadHeroLogo() async {
        guard item.kind != .episode, let url = current.logoURL() else {
            heroLogo = nil
            return
        }
        heroLogo = await AetherImageCache.shared.image(for: url, maxPixel: ArtworkTier.logo.maxPixel)
    }

    /// Outcome of a local-metadata-edit refresh — the view decides whether to
    /// pop (kind changed → the item lives under a different grouping now).
    enum LocalEditOutcome { case kindChanged, updated, skip }

    /// Re-point the screen after the local metadata editor closes (#211). The
    /// `localEditToken != nil` gate stays in the view (it owns the token); this
    /// does the fetch + decides. `dismiss()` stays view-side on `.kindChanged`.
    func refreshAfterLocalEdit() async -> LocalEditOutcome {
        guard activeItem.id.source == .local || isSMBSource(activeItem.id.source),
              let source,
              let refreshed = try? await source.item(for: activeItem.id) else { return .skip }
        if refreshed.kind != activeItem.kind { return .kindChanged }
        // Feeding the refreshed item into `overrideItem` (the same channel the
        // source switch uses) repaints the hero, which reads `activeItem`.
        overrideItem = refreshed
        configuredItem = applyingPreferences(to: refreshed)
        return .updated
    }
}
