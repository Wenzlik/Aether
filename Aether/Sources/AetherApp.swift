import SwiftUI
import AetherCore

#if canImport(UIKit)
import UIKit
#endif

@main
struct AetherApp: App {
    @State private var session = AppSession()

    var body: some Scene {
        WindowGroup {
            RootTabView(session: session)
                .preferredColorScheme(.dark)
                .tint(AetherDesign.Palette.accent)
                .task { await session.start() }
        }
    }
}

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

    // MARK: - UI bridging

    var isSignInPresented: Bool = false

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
    }

    // MARK: - Lifecycle

    func start() async {
        // 0. Hydrate resume points from disk + a one-shot iCloud read, then
        //    start listening for external iCloud changes (other devices on
        //    the same iCloud account writing). Must run before Home / Library
        //    views ask the store for state.
        await resumeStore.loadFromDisk()
        await resumeStore.observeICloudChanges()

        // 1. Plex auth seam.
        await setUpPlex()

        // 2. Restore the persisted Plex server if we have one — this builds the
        //    live source and is what Home renders. No mock fallback.
        await restorePlexServer()

        // 3. If the user is signed in but no server is on file, run discovery
        //    so Home doesn't sit at the empty state forever.
        if isPlexSignedIn && plexServer == nil {
            await discoverPlexServers()
        }
    }

    // MARK: - Plex auth setup

    private func setUpPlex() async {
        let identifier = await ensurePlexClientIdentifier()
        let config = PlexConfiguration(
            product: "Aether",
            version: "0.2.0",
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
            adoptPlexSourceIfAvailable()
        } catch {
            // Reading a corrupted record shouldn't break launch — just leave
            // the user signed-in-but-no-server, which prompts a re-discovery.
        }
    }

    /// Point `source` at the live Plex source once we know which server to
    /// talk to. Called from `restorePlexServer()` on launch and
    /// `discoverPlexServers()` after a fresh selection.
    private func adoptPlexSourceIfAvailable() {
        guard let plexSource else { return }
        source = plexSource
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
    }

    func signOutOfPlex() async {
        do { try await keychain.removeValue(for: Self.plexTokenKey) } catch { }
        do { try await plexServerStore?.clear() } catch { }
        plexServer = nil
        plexSource = nil
        discoveryState = .idle
        isPlexSignedIn = false
        // No mock fallback — Home returns to its "Add a source" welcome state.
        source = nil
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
            adoptPlexSourceIfAvailable()
        } catch {
            discoveryState = .failed(message: error.localizedDescription)
        }
    }

    func presentSignIn() {
        isSignInPresented = true
    }

    // MARK: - Keychain keys

    static let plexClientIdentifierKey = "plex.clientIdentifier"
    static let plexTokenKey = "plex.authToken"

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
