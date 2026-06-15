import SwiftUI
import AetherCore
import Network

#if canImport(UIKit)
import UIKit
#endif

@main
struct AetherApp: App {
    @State private var session = AppSession()
    // Adapter for the one UIKit-shaped callback SwiftUI's app lifecycle
    // doesn't expose: `application(_:handleEventsForBackgroundURLSession:`
    // `completionHandler:)`. Without it iOS keeps the app awake after
    // delivering background download events, burning battery; with it we
    // hand the closure to `BackgroundDownloadCompletions` and let the
    // URLSession bridge release it when all events have been processed.
    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    #if os(visionOS)
    // Cinema Mode (visionOS only). `CinemaManager` is the single source of
    // truth for cinema state; `RootTabView` opens/closes the immersive space and
    // presents the native player on its intent. The space renders only the Dark
    // Theater environment — the system docks the native `AVPlayerViewController`
    // into it. `immersionStyle` defaults to `.progressive` (Apple TV+ / Disney+
    // feel — enter dark, but the Digital Crown dials the real room back in) with
    // `.full` available for true OLED black.
    // See `docs/next-steps/visionos-cinema.md`.
    @State private var cinema = CinemaManager()
    @State private var immersionStyle: any ImmersionStyle = .progressive
    #endif

    var body: some Scene {
        #if os(visionOS)
        // No window dismiss/reopen: the native player docks *out of* this
        // window into the immersive space, so the window stays put (avoids the
        // re-launch churn the earlier design hit).
        WindowGroup {
            RootTabView(session: session)
                .preferredColorScheme(session.appearance.preference.colorScheme)
                // In-app UI language override (#312) — `.system` follows the
                // device language (and the iOS per-app language setting); a
                // specific choice overrides it live. Untranslated strings fall
                // back to the en source language.
                .environment(\.locale, session.language.resolvedLocale)
                .tint(AetherDesign.Palette.accent)
                .environment(\.watchedDisplay, session.playbackPreferences.watchedDisplayConfig)
                .task { await session.start() }
                .environment(session)
                .environment(session.watchAvailability)
                .environment(cinema)
        }
        #else
        WindowGroup {
            RootTabView(session: session)
                .preferredColorScheme(session.appearance.preference.colorScheme)
                // In-app UI language override (#312) — `.system` follows the
                // device language (and the iOS per-app language setting); a
                // specific choice overrides it live. Untranslated strings fall
                // back to the en source language.
                .environment(\.locale, session.language.resolvedLocale)
                .tint(AetherDesign.Palette.accent)
                .environment(\.watchedDisplay, session.playbackPreferences.watchedDisplayConfig)
                .task { await session.start() }
                .environment(session)
                .environment(session.watchAvailability)
        }
        #endif

        #if os(visionOS)
        // A single Dark Theater immersive space. It loads the one authored
        // environment (`AetherDarkTheater.usda`); `DarkTheaterView` reads the
        // live size + seat off `cinema` (set by `present(...)` before open, and
        // changeable in-cinema), so there's no per-preset space.
        ImmersiveSpace(id: CinemaManager.spaceID) {
            DarkTheaterView(cinema: cinema)
        }
        .immersionStyle(selection: $immersionStyle, in: .progressive, .full)
        #endif
    }
}

// MARK: - AppDelegate (background URL session bridge only)

#if canImport(UIKit)
/// Minimal `UIApplicationDelegate` that exists solely to bridge one
/// background `URLSession` callback that SwiftUI's lifecycle doesn't
/// surface. Everything else (scenes, state restoration, push) is handled
/// by SwiftUI's `App` / `Scene` modifiers.
final class AppDelegate: NSObject, UIApplicationDelegate {

    /// Called by iOS when a background `URLSession` event arrives while
    /// the app is suspended. The closure is the OS-side latch: we MUST
    /// invoke it once URLSession reports it's drained its event queue,
    /// otherwise iOS keeps the app held in the background.
    ///
    /// We can't call the closure directly here — URLSession events are
    /// still arriving on the delegate (the `URLSessionEventBridge` owned
    /// by `DownloadManager`). The bridge knows when to flush via its
    /// `urlSessionDidFinishEvents(forBackgroundURLSession:)` callback,
    /// and uses the `BackgroundDownloadCompletions` singleton to find
    /// the closure we stashed here.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            BackgroundDownloadCompletions.shared.storeHandler(
                completionHandler,
                identifier: identifier
            )
        }
    }
}
#endif

/// Owns the long-lived app-wide dependencies: the active media source, the
/// resume store, the playback session, the Plex auth seam, and the Plex
/// server discovery state.
///
/// As of this PR `AppSession` also handles server discovery — read the
/// persisted server on launch, run discovery after sign-in, build a live
/// `PlexMediaSource` from the result. Library browsing arrives in the next PR.
@MainActor
@Observable
final class AppSession {
    // MARK: - Home library

    /// The active source feeding `HomeView`. `nil` until a Plex server is
    /// selected; `HomeView` shows its welcome / empty state in that case.
    /// There is no mock fallback — Aether shows real content or honest states.
    var source: (any MediaSource)?

    var loadError: String?

    // MARK: - Cross-cutting

    let resumeStore: ResumeStore
    let playback: PlaybackSession
    let keychain: KeychainStore
    let api: any APIClient
    let libraryPreferences: LibraryPreferencesStore
    let playbackPreferences: PlaybackPreferencesStore
    /// Default cinema screen-size preset (visionOS). Cross-platform store so the
    /// Settings picker round-trips anywhere; only visionOS renders the cinema.
    let cinemaPreferences: CinemaPreferencesStore
    let appearance: AppearancePreferenceStore
    /// In-app UI language override (#312); `.system` follows the device language.
    let language: LanguagePreferenceStore
    /// Netflix-availability opt-in + region (#360). Off by default.
    let streamingPreferences: StreamingPreferencesStore

    // MARK: - Local Library

    /// On-device files Aether owns (#173). The store is always present; the
    /// source is folded into `connectedSources` only once something's been
    /// imported, so a fresh server-less install still shows the welcome state.
    let localLibraryStore = LocalLibraryStore()
    let localSource: LocalMediaSource
    /// Cached count of imported files (refreshed on launch + after import), so
    /// the synchronous `connectedSources` can decide whether to include Local.
    private(set) var localItemCount = 0

    /// Re-read the imported-file count (after an import or removal).
    func refreshLocalLibrary() async {
        localItemCount = await localLibraryStore.count()
    }

    private static let userTMDbTokenKey = "tmdb.userToken"

    /// A TMDb token the user entered in Settings (#214). When set it's used for
    /// poster matching **instead of** the built-in key — so a missing or
    /// rate-limited built-in key can be fixed in-app without a rebuild. Persisted
    /// in UserDefaults; observed, so the Settings row reflects changes live.
    private(set) var userTMDbToken: String = (UserDefaults.standard.string(forKey: AppSession.userTMDbTokenKey) ?? "")
        .trimmingCharacters(in: .whitespaces)

    /// TMDb v3 key injected at build time (Info.plist ← Config/Secrets.xcconfig
    /// or Xcode Cloud). Empty when none was built in (e.g. some TestFlight builds).
    var builtInTMDbAPIKey: String {
        ((Bundle.main.object(forInfoDictionaryKey: "TMDBAPIKey") as? String) ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// The effective TMDb key for matching: the user's token wins when set, else
    /// the built-in key. Empty ⇒ metadata matching is disabled.
    var tmdbAPIKey: String {
        userTMDbToken.isEmpty ? builtInTMDbAPIKey : userTMDbToken
    }

    /// Whether a built-in key is present (so the UI can label the user token a
    /// "fallback" vs. the only source).
    var hasBuiltInTMDbKey: Bool { !builtInTMDbAPIKey.isEmpty }

    /// Check a token against TMDb before saving it (#214), so the user gets
    /// "valid / rejected / unreachable" feedback instead of silently saving a bad
    /// key. Doesn't persist anything.
    func validateTMDbToken(_ token: String) async -> TMDbClient.ValidationResult {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        return await TMDbClient(apiKey: trimmed, api: api).validate()
    }

    /// Save (or clear, when blank) the user's TMDb token. Rebuilds the SMB source
    /// with the new matcher and clears its remembered misses so unmatched titles
    /// retry on the next browse. Local-library matching reads the key fresh on
    /// each call, so it picks the new token up automatically.
    func setUserTMDbToken(_ token: String) async {
        userTMDbToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if userTMDbToken.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.userTMDbTokenKey)
        } else {
            UserDefaults.standard.set(userTMDbToken, forKey: Self.userTMDbTokenKey)
        }
        if let connection = smbConnection {
            smbSource = SMBMediaSource(connection: connection, tmdb: smbTMDb)
            await SMBMetadataStore.shared.clearMisses()
        }
    }

    /// Enrich a freshly-imported local item with TMDb metadata (poster /
    /// overview / canonical title). Best-effort: no-op without a key or on any
    /// failure, leaving the inferred title in place.
    func matchLocalMetadata(for item: LocalLibraryStore.Item) async {
        guard !tmdbAPIKey.isEmpty else { return }
        if let match = await TMDbClient(apiKey: tmdbAPIKey, api: api)
            .match(title: item.title, year: item.year, isEpisode: item.isEpisode) {
            await localLibraryStore.setMatch(match, for: item.id)
        }
    }

    /// Whether TMDb matching is available (a key was built in).
    var isTMDbConfigured: Bool { !tmdbAPIKey.isEmpty }

    /// Fill in metadata for items imported before a key was present — matches
    /// every still-unmatched item. (Matching otherwise only runs at import.)
    func rematchLocalMetadata() async {
        guard isTMDbConfigured else { return }
        for item in await localLibraryStore.allItems() where item.metadata == nil {
            await matchLocalMetadata(for: item)
        }
        await refreshLocalLibrary()
    }

    // MARK: Local metadata editing (#211)

    /// The stored item backing a local `MediaItem`, for pre-filling the editor.
    func localItem(for id: String) async -> LocalLibraryStore.Item? {
        await localLibraryStore.item(for: id)
    }

    /// Top TMDb candidates so the user can correct a wrong / missing match.
    /// Empty without a key.
    func localMatchCandidates(title: String, year: Int?, isEpisode: Bool, limit: Int = 6) async -> [TMDbMetadata] {
        guard isTMDbConfigured else { return [] }
        return await TMDbClient(apiKey: tmdbAPIKey, api: api)
            .searchCandidates(title: title, year: year, isEpisode: isEpisode, limit: limit)
    }

    /// Apply a user-chosen TMDb candidate as the item's match (poster / overview
    /// / canonical title); the user's text overrides still win on top.
    func applyLocalMatch(_ metadata: TMDbMetadata?, for id: String) async {
        await localLibraryStore.setMatch(metadata, for: id)
    }

    /// Persist the user's per-field corrections (an all-nil/`nil` value clears).
    func saveLocalOverrides(_ overrides: LocalLibraryStore.Item.Overrides?, for id: String) async {
        await localLibraryStore.setOverrides(overrides, for: id)
        await refreshLocalLibrary()
    }

    /// Write custom poster bytes; returns the stored (versioned) filename, or nil.
    @discardableResult
    func saveLocalArtwork(_ data: Data, for id: String) async -> String? {
        await localLibraryStore.setArtwork(data, for: id)
    }

    // MARK: SMB title/year editing (#213)

    /// The user's current title/year correction for an SMB item, for pre-filling
    /// the edit sheet. `nil` when uncorrected or SMB isn't configured.
    func smbOverride(for itemID: MediaID) async -> SMBMetadataStore.Override? {
        await smbSource?.override(forItem: itemID)
    }

    /// Persist a title/year correction for an SMB item (a `nil`/empty value
    /// clears it), then drop the cached walk so the next browse re-matches TMDb
    /// with the corrected title → fresh poster. Detail re-points on dismiss; the
    /// library grid re-walks when next navigated to.
    func saveSMBOverride(_ override: SMBMetadataStore.Override?, for itemID: MediaID) async {
        await smbSource?.setOverride(override, forItem: itemID)
    }

    // MARK: - Downloads

    /// Single-source-of-truth for download state. `nil` until `start()` has
    /// finished its async init; views guard for that during the first paint
    /// (the store + manager need `await` to spin up — initialising
    /// synchronously in `init` would force every test fixture to be async,
    /// so the cost is contained here).
    private(set) var downloadStore: DownloadStore?

    /// Owns the single background `URLSession`. Phase 2.0 wired the
    /// behaviour; Phase 2.1 surfaces it to the UI via the observer below.
    private(set) var downloadManager: DownloadManager?

    /// `@MainActor`-bound mirror of `DownloadStore` for SwiftUI views.
    /// Reads `downloads.snapshot.status(for: item.id)` synchronously from
    /// `body` — no actor hop, no `await` in the render path.
    private(set) var downloads: DownloadObserver?

    /// `@MainActor`-bound mirror of Netflix availability for SwiftUI views
    /// (#360). Cards read `watchAvailability.netflix(forTMDb:)` synchronously;
    /// lookups run in the background and write back. Always present (the feature
    /// gates itself on the opt-in toggle inside the store).
    @ObservationIgnored
    private(set) lazy var watchAvailability = WatchAvailabilityStore(
        preferences: streamingPreferences,
        makeService: { [weak self] in self?.makeWatchProvidersService() }
    )

    // MARK: - Plex — auth

    private(set) var plexConfiguration: PlexConfiguration?
    private(set) var plexAuthClient: PlexAuthClient?
    var isPlexSignedIn: Bool = false

    // MARK: - Plex — server discovery

    private(set) var plexResourceClient: PlexResourceClient?
    private(set) var plexServerStore: PlexServerStore?

    /// The enabled Plex servers — several can be connected at once from one
    /// account (#325). Loaded on launch, set on discovery, edited in the picker.
    /// Ordered best-first (discovery ranking); `.first` is the "primary".
    private(set) var plexServers: [PlexServerRecord] = []

    /// The live `PlexMediaSource`s built from `plexServers`, same order. The
    /// Unified Library fans out over all of them (`connectedSources`); the few
    /// remaining single-source call sites use the primary via `plexSource`.
    private(set) var plexSources: [PlexMediaSource] = []

    /// The primary (first) enabled server — back-compat for single-source
    /// consumers (the Plex account row, Home's On Deck rail, `source`). `nil`
    /// when no Plex server is enabled.
    var plexServer: PlexServerRecord? { plexServers.first }

    /// The primary (first) live source. `nil` until a server is enabled.
    var plexSource: PlexMediaSource? { plexSources.first }

    /// User-visible discovery state. Drives `PlexDiscoveryView`.
    var discoveryState: DiscoveryState = .idle

    enum DiscoveryState: Sendable, Equatable {
        case idle
        case discovering
        case noServersFound
        case failed(message: String)
        case completed(serverName: String)
    }

    // MARK: - Jellyfin

    private(set) var jellyfinConfiguration: JellyfinConfiguration?
    private(set) var jellyfinAuthClient: JellyfinAuthClient?
    private(set) var jellyfinServerStore: JellyfinServerStore?
    var jellyfinServer: JellyfinServerRecord?
    private(set) var jellyfinSource: JellyfinMediaSource?
    var isJellyfinSignedIn: Bool = false

    // MARK: - SMB (#214)

    private(set) var smbConnectionStore: SMBConnectionStore?
    var smbConnection: SMBConnection?
    private(set) var smbSource: SMBMediaSource?
    var isSMBConnected: Bool = false
    /// Whether the connected SMB host is reachable right now. SMB is LAN-only, so
    /// off-network this flips false and `connectedSources` drops the source —
    /// dormant, no errors, hidden from the Library — until we're back (#214).
    /// Optimistic default so a configured share shows instantly on launch; the
    /// probe corrects it within a couple of seconds.
    private(set) var isSMBReachable: Bool = true
    /// Watches network changes to re-probe reachability (home ↔ away).
    private var smbPathMonitor: NWPathMonitor?
    /// Guards against overlapping probes when path changes arrive in a burst.
    private var isProbingSMB = false

    // MARK: - Active source

    /// Which connected source is being browsed. The user can connect both Plex
    /// and Jellyfin; exactly one is active at a time, and the choice persists.
    /// (A merged multi-source feed can be layered on later.) SMB/DLNA are NOT
    /// active-source kinds — they surface only via `connectedSources` (#214).
    enum SourceKind: String, Sendable, CaseIterable {
        case plex
        case jellyfin
    }

    var activeSourceKind: SourceKind?

    // MARK: - UI bridging

    var isSignInPresented: Bool = false
    /// Which onboarding the sign-in sheet should show. Decoupled from
    /// `SourceKind` so SMB/DLNA can be sign-in targets without becoming
    /// active-source kinds (#214).
    enum SignInTarget: Sendable {
        case plex
        case jellyfin
        case smb
    }
    var signInTarget: SignInTarget = .plex

    // MARK: - Init

    init(
        keychain: KeychainStore = KeychainStore(),
        api: any APIClient = URLSessionAPIClient()
    ) {
        // Production-wired ResumeStore: documents-directory JSON file as the
        // local source of truth, NSUbiquitousKeyValueStore for cross-device
        // sync. Defaults (`nil`) on either argument fall back to in-memory,
        // which is what tests rely on.
        let store = ResumeStore(
            diskURL: ResumeStore.defaultDiskURL(),
            icloud: .default
        )
        self.resumeStore = store
        self.playback = PlaybackSession(resumeStore: store)
        self.keychain = keychain
        self.api = api
        self.libraryPreferences = LibraryPreferencesStore(keychain: keychain)
        self.playbackPreferences = PlaybackPreferencesStore()
        self.cinemaPreferences = CinemaPreferencesStore()
        self.appearance = AppearancePreferenceStore()
        self.language = LanguagePreferenceStore()
        self.streamingPreferences = StreamingPreferencesStore()
        self.localSource = LocalMediaSource(store: localLibraryStore)
    }

    // MARK: - Netflix availability (#360)

    /// A `WatchProvidersService` over the current TMDb key + resolved region, or
    /// nil when TMDb isn't configured. Cheap to build (the 24h cache is shared
    /// across instances, so a fresh one still hits warm entries). Region is the
    /// user's Settings choice, else the device region (availability is about
    /// where you physically are, not the UI language).
    func makeWatchProvidersService() -> WatchProvidersService? {
        guard isTMDbConfigured else { return nil }
        let fallback = Locale.current.region?.identifier ?? "US"
        let region = streamingPreferences.resolvedRegion(default: fallback)
        return WatchProvidersService(apiKey: tmdbAPIKey, api: api, region: region, cache: watchProvidersCache)
    }

    /// Shared 24h cache so every `makeWatchProvidersService()` and the badge
    /// store hit the same warm entries instead of re-querying TMDb.
    private let watchProvidersCache = WatchProvidersService.Cache()

    // MARK: - Lifecycle

    /// Guards `start()` against re-running. `RootTabView.task` calls it on
    /// every window appearance — and on visionOS the main window is dismissed
    /// when entering the cinema and reopened on exit, which re-creates
    /// `RootTabView` and would otherwise re-run discovery / rebuild the active
    /// source mid-session (which surfaced as a black cinema on re-entry).
    private var hasStarted = false

    /// `true` from launch until `start()` finishes restoring sources + running
    /// first-time discovery. While it's `true` an empty `connectedSources` means
    /// "still connecting", not "no source" — so the tabs show a loading state
    /// instead of flashing the welcome / empty state before discovery lands.
    private(set) var isStartingUp = true

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        defer { isStartingUp = false }

        // 0. Hydrate resume points from disk + a one-shot iCloud read, then
        //    start listening for external iCloud changes (other devices on
        //    the same iCloud account writing). Must run before Home / Library
        //    views ask the store for state.
        await resumeStore.loadFromDisk()
        await resumeStore.observeICloudChanges()

        // 1. Auth seams for both sources.
        await setUpPlex()
        await setUpJellyfin()

        // 2. Restore persisted servers — these build the live sources.
        await restorePlexServer()
        await restoreJellyfinServer()
        await restoreSMB()

        // 3. Pick the active source (persisted choice, else whatever connected).
        activeSourceKind = await loadActiveSourceKind()
        refreshActiveSource()

        // 3b. Count any previously-imported Local Library files so it folds into
        //     `connectedSources` from first paint.
        await refreshLocalLibrary()

        // 4. Boot the downloads pipeline. The store reads its JSON file off
        //    disk; the manager rebinds any in-flight URLSession tasks from
        //    a previous launch. Both are idempotent. The observer is a
        //    `@MainActor`-bound mirror SwiftUI views can read directly.
        //    Attaching the store to PlaybackSession is what enables the
        //    offline override: completed downloads play from disk without
        //    touching the source layer.
        let store = await DownloadStore()
        let manager = await DownloadManager(store: store)
        downloadStore = store
        downloadManager = manager
        downloads = DownloadObserver(store: store)
        await playback.attachDownloadStore(store)

        // 5. If Plex is signed in but no server is on file, run discovery so
        //    Home doesn't sit at the empty state forever.
        if isPlexSignedIn && plexServer == nil {
            await discoverPlexServers()
        }
    }

    // MARK: - Plex auth setup

    private func setUpPlex() async {
        let identifier = await ensurePlexClientIdentifier()
        let config = PlexConfiguration(
            product: "Aether",
            version: "0.3.0",
            clientIdentifier: identifier,
            deviceName: currentDeviceName,
            platform: currentPlatform,
            platformVersion: currentPlatformVersion
        )
        plexConfiguration = config
        plexAuthClient = PlexAuthClient(api: api, configuration: config)
        plexResourceClient = PlexResourceClient(api: api, configuration: config)
        plexServerStore = PlexServerStore(keychain: keychain)

        do {
            if let token = try await keychain.string(for: Self.plexTokenKey), !token.isEmpty {
                isPlexSignedIn = true
            }
        } catch {
            // Keychain unavailable — user can re-sign-in.
        }
    }

    private func ensurePlexClientIdentifier() async -> String {
        do {
            if let existing = try await keychain.string(for: Self.plexClientIdentifierKey), !existing.isEmpty {
                return existing
            }
            let new = UUID().uuidString
            try await keychain.setString(new, for: Self.plexClientIdentifierKey)
            return new
        } catch {
            return UUID().uuidString
        }
    }

    // MARK: - Server persistence + restore

    private func restorePlexServer() async {
        guard let store = plexServerStore else { return }
        do {
            let records = try await store.readAll()
            guard !records.isEmpty else { return }
            applyEnabledPlexServers(records)
        } catch {
            // Reading a corrupted record shouldn't break launch — just leave
            // the user signed-in-but-no-server, which prompts a re-discovery.
        }
    }

    /// Re-point `source` at the active connected source (Plex or Jellyfin),
    /// falling back to whichever is available. Called after any source's
    /// availability or the active choice changes.
    private func refreshActiveSource() {
        switch activeSourceKind {
        case .jellyfin:
            source = jellyfinSource ?? plexSource
        case .plex:
            source = plexSource ?? jellyfinSource
        case nil:
            source = plexSource ?? jellyfinSource
        }
    }

    // MARK: - Unified Library (all connected sources)

    /// Every currently-connected source (Plex + Jellyfin). Distinct from
    /// `source`, the single active one the not-yet-unified Library / Detail
    /// paths still use. Unified surfaces (Home / Search, Phase 2b+) read this.
    var connectedSources: [any MediaSource] {
        var list: [any MediaSource] = []
        // All enabled Plex servers — the Unified Library merges + dedupes them
        // (and Jellyfin/SMB/Local) by shared external ids (#325).
        list.append(contentsOf: plexSources)
        if let jellyfinSource { list.append(jellyfinSource) }
        // SMB is LAN-only — surface it only while the NAS is actually reachable,
        // so off-network it goes dormant (no failed walks, not shown in the
        // Library) and auto-reappears when you're back on the network (#214).
        if let smbSource, isSMBReachable { list.append(smbSource) }
        // Local is on-device + always available, but only counts as a connected
        // source once it has content — otherwise a fresh server-less install
        // would never show the "connect a source" welcome state.
        if localItemCount > 0 { list.append(localSource) }
        return list
    }

    /// Display names keyed by source id — for the unified "Available Sources"
    /// rows on Detail. Read through the `any MediaSource` existentials (the
    /// protocol witness for `id`/`displayName` is synchronous; the concrete
    /// actor properties are isolated).
    var sourceDisplayNames: [MediaSourceID: String] {
        var names: [MediaSourceID: String] = [:]
        for source in connectedSources {
            names[source.id] = source.displayName
        }
        return names
    }

    /// A `UnifiedLibrary` over the connected sources + downloads. Built on
    /// demand (cheap) so it always reflects the current connection set.
    func makeUnifiedLibrary() -> UnifiedLibrary {
        UnifiedLibrary(sources: connectedSources, downloads: downloadStore)
    }

    /// Mark a played item watched/unwatched on **every connected source** that
    /// has it (matched by shared external id), not just the one it streamed
    /// from — so a title on both Plex and Jellyfin stays in sync.
    func markWatchedEverywhere(_ item: MediaItem, watched: Bool = true) async {
        await makeUnifiedLibrary().markWatchedEverywhere(item, watched: watched)
    }

    /// Make `kind` the active source (persisted) and re-point `source`.
    func setActiveSource(_ kind: SourceKind) {
        activeSourceKind = kind
        Task { try? await keychain.setString(kind.rawValue, for: Self.activeSourceKey) }
        refreshActiveSource()
    }

    private func loadActiveSourceKind() async -> SourceKind? {
        if let raw = try? await keychain.string(for: Self.activeSourceKey),
           let kind = SourceKind(rawValue: raw) {
            return kind
        }
        // No stored choice: default to whatever is connected (Plex wins ties).
        if isPlexSignedIn { return .plex }
        if isJellyfinSignedIn { return .jellyfin }
        return nil
    }

    private func makePlexSource(from record: PlexServerRecord) -> PlexMediaSource? {
        guard let config = plexConfiguration, !record.connections.isEmpty else { return nil }
        return PlexMediaSource(
            serverID: record.clientIdentifier,
            displayName: record.name,
            accessToken: record.accessToken,
            connections: record.connections,
            configuration: config,
            api: api
        )
    }

    // MARK: - Sign-in completion

    /// Called by `PlexSignInView` after a successful PIN exchange.
    ///
    /// Persists the auth token, flips `isPlexSignedIn`, then kicks off server
    /// discovery so the onboarding flow moves directly into the next step
    /// without the user having to tap a separate "Discover servers" button.
    func completePlexSignIn(token: String) async {
        do {
            try await keychain.setString(token, for: Self.plexTokenKey)
        } catch { }
        isPlexSignedIn = true
        await discoverPlexServers()
        // A fresh Plex sign-in becomes the active source.
        if plexSource != nil { setActiveSource(.plex) }
    }

    func signOutOfPlex() async {
        do { try await keychain.removeValue(for: Self.plexTokenKey) } catch { }
        do { try await plexServerStore?.clear() } catch { }
        // Drop the cross-launch library snapshot so a signed-out account's
        // catalog can't be read off disk (#197).
        await UnifiedLibrarySnapshotStore.shared.clearAll()
        plexServers = []
        plexSources = []
        discoveryState = .idle
        isPlexSignedIn = false
        // Fall back to Jellyfin if it's connected, otherwise the welcome state.
        if activeSourceKind == .plex {
            setActiveSource(isJellyfinSignedIn ? .jellyfin : .plex)
        } else {
            refreshActiveSource()
        }
    }

    // MARK: - Server discovery

    /// Fetch resources, pick the best server, persist, build the source.
    /// Safe to call repeatedly (e.g. on `Try again`); it always re-fetches.
    func discoverPlexServers() async {
        guard
            let resourceClient = plexResourceClient,
            plexServerStore != nil
        else {
            discoveryState = .failed(message: "Plex isn't set up yet.")
            return
        }

        let token: String
        do {
            guard let stored = try await keychain.string(for: Self.plexTokenKey), !stored.isEmpty else {
                discoveryState = .failed(message: "No Plex token on file. Sign in first.")
                return
            }
            token = stored
        } catch {
            discoveryState = .failed(message: "Couldn't read your Plex credentials.")
            return
        }

        discoveryState = .discovering

        do {
            let resources = try await resourceClient.resources(token: token)
            let selector = PlexServerSelector()
            guard let pick = selector.selectBest(from: resources) else {
                discoveryState = .noServersFound
                return
            }

            // First connect auto-enables the single best server (unchanged from
            // single-server behaviour); the user adds others in the picker
            // (#325). If servers are already enabled, leave the set intact.
            if plexServers.isEmpty {
                await setEnabledPlexServers([pick.makeRecord()])
            } else {
                discoveryState = .completed(serverName: plexServer?.name ?? pick.server.name)
            }
        } catch {
            discoveryState = .failed(message: error.localizedDescription)
        }
    }

    // MARK: - Server picker (#323 / #325)

    /// Every Plex server the account can currently reach, ranked best-first.
    ///
    /// Re-fetches resources live (the reachable set changes with the network —
    /// a LAN server drops off when you leave the house), so the Settings picker
    /// always reflects what's actually connectable right now. Returns `[]` when
    /// Plex isn't set up or no token is on file; throws only on the network /
    /// decode failure, so the caller can show "couldn't load servers".
    func availablePlexServers() async throws -> [PlexServerRecord] {
        guard let resourceClient = plexResourceClient,
              let token = try? await keychain.string(for: Self.plexTokenKey),
              !token.isEmpty
        else { return [] }

        let resources = try await resourceClient.resources(token: token)
        return PlexServerSelector()
            .rankedSelections(from: resources)
            .map { $0.makeRecord() }
    }

    /// Currently-enabled server ids — marks the toggled rows in the picker.
    var enabledPlexServerIDs: Set<String> {
        Set(plexServers.map(\.clientIdentifier))
    }

    /// Enable or disable a Plex server (toggled in the Settings picker, #325).
    /// Several servers from one account can be on at once; their content merges
    /// in the Unified Library. The last enabled server can't be turned off here —
    /// use **Sign Out** to disconnect Plex entirely.
    func setPlexServerEnabled(_ record: PlexServerRecord, enabled: Bool) async {
        var records = plexServers
        if enabled {
            guard !records.contains(where: { $0.clientIdentifier == record.clientIdentifier }) else { return }
            records.append(record)
        } else {
            guard records.count > 1 else { return }   // keep at least one enabled
            records.removeAll { $0.clientIdentifier == record.clientIdentifier }
        }
        await setEnabledPlexServers(records)
        if plexSource != nil { setActiveSource(.plex) }
    }

    /// Set the enabled-servers list, rebuild the live sources, and persist.
    private func setEnabledPlexServers(_ records: [PlexServerRecord]) async {
        applyEnabledPlexServers(records)
        do { try await plexServerStore?.writeAll(records) } catch { }
    }

    /// In-memory apply (no persistence): rebuild sources, mark discovery
    /// complete, re-point the active source. Shared by restore + `setEnabled…`,
    /// and the seam tests use to seed a connected-server state.
    func applyEnabledPlexServers(_ records: [PlexServerRecord]) {
        plexServers = records
        plexSources = records.compactMap { makePlexSource(from: $0) }
        if let primary = records.first {
            discoveryState = .completed(serverName: primary.name)
        }
        refreshActiveSource()
    }

    // MARK: - Jellyfin setup + lifecycle

    private func setUpJellyfin() async {
        let deviceID = await ensureJellyfinDeviceID()
        let config = JellyfinConfiguration(
            client: "Aether",
            version: "0.3.0",
            deviceName: currentDeviceName,
            deviceID: deviceID
        )
        jellyfinConfiguration = config
        jellyfinAuthClient = JellyfinAuthClient(api: api, configuration: config)
        jellyfinServerStore = JellyfinServerStore(keychain: keychain)
    }

    private func ensureJellyfinDeviceID() async -> String {
        do {
            if let existing = try await keychain.string(for: Self.jellyfinDeviceIDKey), !existing.isEmpty {
                return existing
            }
            let new = UUID().uuidString
            try await keychain.setString(new, for: Self.jellyfinDeviceIDKey)
            return new
        } catch {
            return UUID().uuidString
        }
    }

    private func restoreJellyfinServer() async {
        guard let store = jellyfinServerStore else { return }
        do {
            guard let record = try await store.read() else { return }
            jellyfinServer = record
            jellyfinSource = makeJellyfinSource(from: record)
            isJellyfinSignedIn = jellyfinSource != nil
            refreshActiveSource()
        } catch {
            // Corrupted record shouldn't break launch — leave Jellyfin disconnected.
        }
    }

    private func makeJellyfinSource(from record: JellyfinServerRecord) -> JellyfinMediaSource? {
        guard let config = jellyfinConfiguration, let base = record.baseURL else { return nil }
        return JellyfinMediaSource(
            serverID: record.baseURLString,
            displayName: record.serverName,
            baseURL: base,
            accessToken: record.accessToken,
            userID: record.userID,
            configuration: config,
            api: api
        )
    }

    /// Called by `JellyfinSignInView` after a successful Quick Connect exchange.
    func completeJellyfinSignIn(record: JellyfinServerRecord) async {
        do { try await jellyfinServerStore?.write(record) } catch { }
        jellyfinServer = record
        jellyfinSource = makeJellyfinSource(from: record)
        isJellyfinSignedIn = jellyfinSource != nil
        if jellyfinSource != nil { setActiveSource(.jellyfin) }
        isSignInPresented = false
    }

    func signOutOfJellyfin() async {
        do { try await jellyfinServerStore?.clear() } catch { }
        await UnifiedLibrarySnapshotStore.shared.clearAll()
        jellyfinServer = nil
        jellyfinSource = nil
        isJellyfinSignedIn = false
        if activeSourceKind == .jellyfin {
            setActiveSource(isPlexSignedIn ? .plex : .jellyfin)
        } else {
            refreshActiveSource()
        }
    }

    func presentSignIn(_ target: SignInTarget = .plex) {
        signInTarget = target
        isSignInPresented = true
    }

    // MARK: - SMB (#214)

    /// TMDb matcher handed to `SMBMediaSource` so SMB titles get posters/overview
    /// (SMB files carry no artwork). `nil` when no key is built in.
    private var smbTMDb: TMDbClient? {
        isTMDbConfigured ? TMDbClient(apiKey: tmdbAPIKey, api: api) : nil
    }

    private func restoreSMB() async {
        let store = SMBConnectionStore(keychain: keychain)
        smbConnectionStore = store
        do {
            guard let connection = try await store.read() else { return }
            smbConnection = connection
            smbSource = SMBMediaSource(connection: connection, tmdb: smbTMDb)
            isSMBConnected = true
            startSMBReachabilityMonitoring()
            await refreshSMBReachability()
        } catch {
            // Corrupted record shouldn't break launch — leave SMB disconnected.
        }
    }

    /// Called by `SMBConnectView` after the user enters + validates a share.
    func completeSMBSignIn(connection: SMBConnection) async {
        if smbConnectionStore == nil { smbConnectionStore = SMBConnectionStore(keychain: keychain) }
        do { try await smbConnectionStore?.write(connection) } catch { }
        smbConnection = connection
        smbSource = SMBMediaSource(connection: connection, tmdb: smbTMDb)
        isSMBConnected = true
        isSMBReachable = true   // just validated, so it's reachable now
        isSignInPresented = false
        startSMBReachabilityMonitoring()
    }

    // MARK: SMB reachability (LAN-only dormancy, #214)

    /// Re-probe whenever the network path changes (home ↔ away / Wi-Fi ↔ cellular).
    private func startSMBReachabilityMonitoring() {
        guard smbPathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        smbPathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in await self?.refreshSMBReachability() }
        }
        monitor.start(queue: DispatchQueue(label: "cz.zmrhal.aether.smb-reachability"))
    }

    /// Probe the configured SMB host; flip `isSMBReachable` (which gates
    /// `connectedSources`). On a reachable→unreachable→reachable transition,
    /// drop the cached walk + unified snapshot so the share re-scans fresh when
    /// it comes back. A short timeout keeps it snappy on cellular.
    func refreshSMBReachability() async {
        guard let host = smbConnection?.host, !isProbingSMB else { return }
        isProbingSMB = true
        defer { isProbingSMB = false }
        let reachable = await SMBNetworkProbe.probe(host: host, timeoutSeconds: 3) == .reachable
        guard reachable != isSMBReachable else { return }
        isSMBReachable = reachable
        if reachable {
            // Back on the network — clear stale caches so the next browse re-walks.
            await smbSource?.invalidate()
            await UnifiedLibrarySnapshotStore.shared.clearAll()
        }
    }

    /// Change which folders the connected SMB share scans (#214) — add or remove
    /// folders after sign-in (the picker was previously only reachable at
    /// sign-in). Persists the new roots, rebuilds the source, and drops the
    /// cached walk so the new set is scanned on the next browse.
    func updateSMBRoots(_ roots: [String]) async {
        guard var connection = smbConnection, connection.roots != roots else { return }
        connection.roots = roots
        do { try await smbConnectionStore?.write(connection) } catch { }
        smbConnection = connection
        smbSource = SMBMediaSource(connection: connection, tmdb: smbTMDb)
        await UnifiedLibrarySnapshotStore.shared.clearAll()
    }

    func signOutOfSMB() async {
        smbPathMonitor?.cancel()
        smbPathMonitor = nil
        do { try await smbConnectionStore?.clear() } catch { }
        await UnifiedLibrarySnapshotStore.shared.clearAll()
        smbConnection = nil
        smbSource = nil
        isSMBConnected = false
        isSMBReachable = true   // reset for the next connection
    }

    // MARK: - Keychain keys

    static let plexClientIdentifierKey = "plex.clientIdentifier"
    static let plexTokenKey = "plex.authToken"
    static let jellyfinDeviceIDKey = "jellyfin.deviceID"
    static let activeSourceKey = "active.source"

    // MARK: - Platform identity

    private var currentDeviceName: String {
        #if os(tvOS)
        return "Apple TV"
        #elseif os(visionOS)
        return "Apple Vision Pro"
        #elseif os(iOS)
        return UIDevice.current.name
        #else
        return "Mac"
        #endif
    }

    private var currentPlatform: String {
        #if os(tvOS)
        return "tvOS"
        #elseif os(visionOS)
        // Identify as **iOS** to Plex. Plex's universal transcoder selects a
        // per-platform profile from `X-Plex-Platform`; "visionOS" isn't in
        // its known set and the server returns 404 →
        // `NSURLErrorResourceUnavailable` (-1008) on AVPlayer. visionOS's
        // playback stack is functionally iOS (AVKit, HLS, H.264 / HEVC), so
        // the lie is safe and unblocks playback. `currentDeviceName` still
        // reports "Apple Vision Pro", so Plex's session / device list shows
        // the real hardware.
        return "iOS"
        #elseif os(iOS)
        return "iOS"
        #else
        return "macOS"
        #endif
    }

    private var currentPlatformVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }
}
