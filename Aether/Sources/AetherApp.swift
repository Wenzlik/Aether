import SwiftUI
import AetherCore

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
                .tint(AetherDesign.Palette.accent)
                .task { await session.start() }
                .environment(cinema)
        }
        #else
        WindowGroup {
            RootTabView(session: session)
                .preferredColorScheme(session.appearance.preference.colorScheme)
                .tint(AetherDesign.Palette.accent)
                .task { await session.start() }
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

    // MARK: - Plex — auth

    private(set) var plexConfiguration: PlexConfiguration?
    private(set) var plexAuthClient: PlexAuthClient?
    var isPlexSignedIn: Bool = false

    // MARK: - Plex — server discovery

    private(set) var plexResourceClient: PlexResourceClient?
    private(set) var plexServerStore: PlexServerStore?

    /// The currently-selected server (loaded on launch or set on discovery).
    var plexServer: PlexServerRecord?

    /// The live `PlexMediaSource` built from `plexServer`. `nil` until either
    /// the persisted server is loaded on launch or discovery completes.
    private(set) var plexSource: PlexMediaSource?

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

    // MARK: - Active source

    /// Which connected source is being browsed. The user can connect both Plex
    /// and Jellyfin; exactly one is active at a time, and the choice persists.
    /// (A merged multi-source feed can be layered on later.)
    enum SourceKind: String, Sendable, CaseIterable {
        case plex
        case jellyfin
    }

    var activeSourceKind: SourceKind?

    // MARK: - UI bridging

    var isSignInPresented: Bool = false
    /// Which onboarding the sign-in sheet should show.
    var signInTarget: SourceKind = .plex

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
    }

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

        // 3. Pick the active source (persisted choice, else whatever connected).
        activeSourceKind = await loadActiveSourceKind()
        refreshActiveSource()

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
            guard let record = try await store.read() else { return }
            plexServer = record
            plexSource = makePlexSource(from: record)
            discoveryState = .completed(serverName: record.name)
            refreshActiveSource()
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
        if let plexSource { list.append(plexSource) }
        if let jellyfinSource { list.append(jellyfinSource) }
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
        plexServer = nil
        plexSource = nil
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
            let store = plexServerStore
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

            let record = pick.makeRecord()
            try await store.write(record)
            plexServer = record
            plexSource = makePlexSource(from: record)
            discoveryState = .completed(serverName: record.name)
            refreshActiveSource()
        } catch {
            discoveryState = .failed(message: error.localizedDescription)
        }
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

    func presentSignIn(_ target: SourceKind = .plex) {
        signInTarget = target
        isSignInPresented = true
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
