import SwiftUI
import AetherCore

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
/// resume store, the single playback session, and the Plex auth seam.
///
/// In 0.1 this loaded the mock library. As of 0.2 it also owns the
/// `PlexAuthClient` and the persisted Plex sign-in state. Server discovery
/// and a `PlexMediaSource` instance arrive in the next PR.
@MainActor
@Observable
final class AppSession {
    // Mock / production library
    var source: (any MediaSource)?
    var loadError: String?

    // Cross-cutting
    let resumeStore: ResumeStore
    let playback: PlaybackSession
    let keychain: KeychainStore
    let api: any APIClient

    // Plex
    private(set) var plexConfiguration: PlexConfiguration?
    private(set) var plexAuthClient: PlexAuthClient?
    var isPlexSignedIn: Bool = false

    // UI bridging
    var isSignInPresented: Bool = false

    init() {
        let store = ResumeStore()
        self.resumeStore = store
        self.playback = PlaybackSession(resumeStore: store)
        self.keychain = KeychainStore()
        self.api = URLSessionAPIClient()
    }

    // MARK: - Lifecycle

    func start() async {
        // 1. Load the mock library so 0.1 functionality still works.
        do {
            let mock = try MockMediaSource.loadFromBundle()
            for point in await mock.simulatedResumePoints {
                await resumeStore.record(point)
            }
            source = mock
        } catch {
            source = MockMediaSource()
            loadError = "Couldn't load MockLibrary.json — using built-in sample. (\(error.localizedDescription))"
        }

        // 2. Set up the Plex seam (auth client + signed-in flag).
        await setUpPlex()
    }

    // MARK: - Plex

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

        // If we've already stored a token, mark signed-in. (Server discovery is
        // a follow-up PR — the flag here is what the empty state reads.)
        do {
            if let token = try await keychain.string(for: Self.plexTokenKey), !token.isEmpty {
                isPlexSignedIn = true
            }
        } catch {
            // Keychain failure is non-fatal: user can re-sign-in.
        }
    }

    /// Read the per-install Plex client identifier from Keychain, or generate
    /// and persist a fresh one the first time.
    private func ensurePlexClientIdentifier() async -> String {
        do {
            if let existing = try await keychain.string(for: Self.plexClientIdentifierKey), !existing.isEmpty {
                return existing
            }
            let new = UUID().uuidString
            try await keychain.setString(new, for: Self.plexClientIdentifierKey)
            return new
        } catch {
            // Keychain unavailable (unlikely on Apple platforms) — fall back to
            // a UUID per run. Plex still functions; resume scoping just won't
            // stick across launches.
            return UUID().uuidString
        }
    }

    /// Called by the sign-in view after a successful PIN exchange.
    func completePlexSignIn(token: String) async {
        do {
            try await keychain.setString(token, for: Self.plexTokenKey)
        } catch {
            // Persistence failed — user can re-sign in next time.
        }
        isPlexSignedIn = true
        isSignInPresented = false
    }

    func signOutOfPlex() async {
        do { try await keychain.removeValue(for: Self.plexTokenKey) } catch { }
        isPlexSignedIn = false
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
        #elseif os(iOS)
        return UIDevice.current.name
        #else
        return "Mac"
        #endif
    }

    private var currentPlatform: String {
        #if os(tvOS)
        return "tvOS"
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

#if canImport(UIKit)
import UIKit
#endif

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
                    onAddSource: { session.presentSignIn() }
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
            if let authClient = session.plexAuthClient {
                PlexSignInView(
                    authClient: authClient,
                    onSuccess: { token in
                        Task { await session.completePlexSignIn(token: token) }
                    },
                    onCancel: {
                        session.isSignInPresented = false
                    }
                )
            }
        }
    }
}
