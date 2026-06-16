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
}
