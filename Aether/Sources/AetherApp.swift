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
            RootView(session: session)
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
    // MARK: - Mock / Home library

    /// The active source feeding `HomeView`. Starts as the mock fixture and
    /// gets swapped to `plexSource` when a Plex server is selected.
    var source: (any MediaSource)?

    /// The mock fixture, kept around so sign-out can fall back to it instead
    /// of leaving Home with no source at all.
    private var mockSource: (any MediaSource)?

    var loadError: String?

    // MARK: - Cross-cutting

    let resumeStore: ResumeStore
    let playback: PlaybackSession
    let keychain: KeychainStore
    let api: any APIClient

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

    init() {
        let store = ResumeStore()
        self.resumeStore = store
        self.playback = PlaybackSession(resumeStore: store)
        self.keychain = KeychainStore()
        self.api = URLSessionAPIClient()
    }

    // MARK: - Lifecycle

    func start() async {
        // 1. Mock library so 0.1 functionality still works.
        do {
            let mock = try MockMediaSource.loadFromBundle()
            for point in await mock.simulatedResumePoints {
                await resumeStore.record(point)
            }
            mockSource = mock
            source = mock
        } catch {
            let fallback = MockMediaSource()
            mockSource = fallback
            source = fallback
            loadError = "Couldn't load MockLibrary.json — using built-in sample. (\(error.localizedDescription))"
        }

        // 2. Plex auth seam.
        await setUpPlex()

        // 3. Restore the persisted Plex server if we have one.
        await restorePlexServer()

        // 4. If the user is already signed in but no server is on file
        //    (e.g. upgraded from a build where sign-in happened but discovery
        //    didn't exist yet), kick off discovery now so the Home empty
        //    state doesn't sit at "Signed in to Plex" forever.
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

    /// Swap `source` to the live Plex source when one exists.
    ///
    /// The mock fixture stays around as a fallback (loaded earlier in
    /// `start()`), but as soon as we know which Plex server to talk to, we
    /// prefer real content over fake. Called from both `restorePlexServer()`
    /// on launch and `discoverPlexServers()` after a fresh selection.
    private func adoptPlexSourceIfAvailable() {
        guard let plexSource else { return }
        source = plexSource
    }

    private func makePlexSource(from record: PlexServerRecord) -> PlexMediaSource? {
        guard let baseURL = record.baseURL, let config = plexConfiguration else { return nil }
        return PlexMediaSource(
            serverID: record.clientIdentifier,
            displayName: record.name,
            baseURL: baseURL,
            accessToken: record.accessToken,
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
        // Fall back to the mock so Home isn't left pointing at a dead source.
        source = mockSource
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
        return "visionOS"
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

// MARK: - Root

private struct RootView: View {
    @Bindable var session: AppSession

    var body: some View {
        Group {
            if let source = session.source {
                HomeView(
                    source: source,
                    resumeStore: session.resumeStore,
                    playbackSession: session.playback,
                    isPlexSignedIn: session.isPlexSignedIn,
                    plexServerName: session.plexServer?.name,
                    plexDiscoveryState: session.discoveryState,
                    onAddSource: { session.presentSignIn() },
                    onRetryDiscovery: { Task { await session.discoverPlexServers() } }
                )
            } else {
                // Brief, calm boot state — no spinner.
                VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
                    Text("Aether")
                        .font(AetherDesign.Typography.heroTitle)
                        .foregroundStyle(AetherDesign.Palette.textPrimary)
                }
                .padding(AetherDesign.Spacing.l)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(AetherDesign.Palette.background.ignoresSafeArea())
            }
        }
        .sheet(isPresented: $session.isSignInPresented) {
            PlexOnboardingView(session: session)
        }
    }
}

/// Switches between the sign-in step and the discovery step based on
/// `AppSession` state. Lives here (not its own file) because it's pure glue.
private struct PlexOnboardingView: View {
    @Bindable var session: AppSession

    var body: some View {
        if session.isPlexSignedIn {
            PlexDiscoveryView(
                state: session.discoveryState,
                onRetry: { Task { await session.discoverPlexServers() } },
                onClose: { session.isSignInPresented = false }
            )
        } else if let authClient = session.plexAuthClient {
            PlexSignInView(
                authClient: authClient,
                onSuccess: { token in
                    Task { await session.completePlexSignIn(token: token) }
                },
                onCancel: { session.isSignInPresented = false }
            )
        }
    }
}
