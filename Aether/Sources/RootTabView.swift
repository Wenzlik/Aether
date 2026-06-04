import SwiftUI
import AetherCore
#if os(visionOS)
import os
#endif

/// The app's root. A native `TabView` renders as the tvOS 26 top tab bar (and
/// the bottom bar / ornament on iOS / iPadOS / visionOS) — one structure, no
/// per-platform layouts, no sidebar. Replaces the old single-`HomeView`
/// surface-switcher and the Settings `.sheet`.
///
/// Tabs: **Home / Library / Search / Settings**. Each content tab owns its own
/// `NavigationStack` so drilling into a title and switching tabs don't fight
/// over one path. Settings is now a full-screen destination, not a modal.
struct RootTabView: View {
    @Bindable var session: AppSession

    /// tvOS deliberately has no downloads / local library — large-screen
    /// "lean back" consumption assumes a persistent network, and the device
    /// has no swipe gesture for managing rows anyway. Passing `nil` here
    /// makes every DetailView / Library-rail download surface gate itself
    /// out (`shouldShowDownloadControl`, `hasAnyDownloads`) on this platform.
    private var dlManager: DownloadManager? {
        #if os(tvOS)
        nil
        #else
        session.downloadManager
        #endif
    }

    private var dlObserver: DownloadObserver? {
        #if os(tvOS)
        nil
        #else
        session.downloads
        #endif
    }

    #if os(visionOS)
    // Cinema Mode bridge. `CinemaManager` is the single source of truth; the
    // open/dismiss-immersive-space actions are only reachable from a view, so
    // the space transition happens here on the manager's intent. The native
    // player (DetailView's `PlayerView`) docks into the open space.
    // See `docs/next-steps/visionos-cinema.md` → Part 2.
    @Environment(CinemaManager.self) private var cinema
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    #endif

    var body: some View {
        TabView {
            Tab("Home", systemImage: "house.fill") {
                HomeView(
                    source: session.source,
                    resumeStore: session.resumeStore,
                    playbackSession: session.playback,
                    libraryPreferences: session.libraryPreferences,
                    isPlexSignedIn: session.isPlexSignedIn,
                    plexServerName: session.plexServer?.name,
                    plexDiscoveryState: session.discoveryState,
                    onAddSource: { session.presentSignIn() },
                    onRetryDiscovery: { Task { await session.discoverPlexServers() } },
                    downloadManager: dlManager,
                    downloads: dlObserver,
                    playbackPreferences: session.playbackPreferences
                )
            }

            Tab("Library", systemImage: "rectangle.stack.fill") {
                LibraryBrowseView(
                    source: session.source,
                    resumeStore: session.resumeStore,
                    playbackSession: session.playback,
                    libraryPreferences: session.libraryPreferences,
                    onAddSource: { session.presentSignIn() },
                    downloadManager: dlManager,
                    downloads: dlObserver,
                    playbackPreferences: session.playbackPreferences
                )
            }

            #if os(tvOS)
            // Discover replaces Storage on Apple TV — downloads make no
            // sense on a lean-back surface, but content discovery does.
            Tab("Discover", systemImage: "sparkles") {
                DiscoverView(
                    source: session.source,
                    resumeStore: session.resumeStore,
                    playbackSession: session.playback,
                    libraryPreferences: session.libraryPreferences,
                    downloadManager: dlManager,
                    downloads: dlObserver,
                    playbackPreferences: session.playbackPreferences
                )
            }
            #else
            Tab("Storage", systemImage: "internaldrive") {
                StorageView(
                    source: session.source,
                    resumeStore: session.resumeStore,
                    playbackSession: session.playback,
                    libraryPreferences: session.libraryPreferences,
                    downloadManager: session.downloadManager,
                    downloads: session.downloads,
                    playbackPreferences: session.playbackPreferences
                )
            }
            #endif

            Tab("Settings", systemImage: "gearshape.fill") {
                SettingsView(viewModel: SettingsViewModel(session: session))
            }
        }
        .sheet(isPresented: $session.isSignInPresented) {
            switch session.signInTarget {
            case .plex:
                PlexOnboardingView(session: session)
            case .jellyfin:
                JellyfinSignInView(session: session)
            }
        }
        #if os(visionOS)
        .onChange(of: cinema.openRequestID) { _, id in
            guard id != nil else { return }
            let log = Logger(subsystem: "cz.zmrhal.aether", category: "cinema")
            Task {
                // Open the Dark Theater. DetailView presents the native player;
                // the system docks it into this space.
                let result = await openImmersiveSpace(id: CinemaManager.spaceID)
                log.debug("openImmersiveSpace result=\(String(describing: result), privacy: .public)")
                if case .opened = result {
                    // Docked — nothing more to do here.
                } else {
                    // Failed / cancelled — leave cinema state so we don't strand.
                    cinema.end()
                }
            }
        }
        .onChange(of: cinema.closeRequestID) { _, id in
            guard id != nil else { return }
            let log = Logger(subsystem: "cz.zmrhal.aether", category: "cinema")
            log.debug("closeRequestID → dismissImmersiveSpace")
            Task { await dismissImmersiveSpace() }
        }
        #endif
    }
}

/// Switches between the sign-in step and the discovery step based on
/// `AppSession` state. Pure glue, so it sits next to `RootTabView`.
struct PlexOnboardingView: View {
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

// MARK: - Shared navigation destinations

/// Registers the `MediaItem` → `DetailView` and `Library` → `LibraryView`
/// destinations once, so every tab's `NavigationStack` (Home, Library, Search)
/// pushes the same screens without copying the wiring three times.
private struct MediaNavigationDestinations: ViewModifier {
    let source: (any MediaSource)?
    let resumeStore: ResumeStore
    let playbackSession: PlaybackSession
    let libraryPreferences: LibraryPreferencesStore
    /// Optional — `nil` before `AppSession.start()` has booted the
    /// downloads pipeline, which is the only window where DetailView
    /// can be reached without it (cold-launch deep link, theoretically).
    let downloadManager: DownloadManager?
    let downloads: DownloadObserver?
    /// App-wide playback defaults seeded into DetailView's pickers.
    let playbackPreferences: PlaybackPreferencesStore?

    func body(content: Content) -> some View {
        content
            .navigationDestination(for: MediaItem.self) { item in
                DetailView(
                    item: item,
                    source: source,
                    resumeStore: resumeStore,
                    playbackSession: playbackSession,
                    downloadManager: downloadManager,
                    downloads: downloads,
                    playbackPreferences: playbackPreferences
                )
            }
            .navigationDestination(for: Library.self) { library in
                LibraryView(
                    library: library,
                    source: source,
                    resumeStore: resumeStore,
                    playbackSession: playbackSession,
                    libraryPreferences: libraryPreferences
                )
            }
    }
}

extension View {
    func mediaNavigationDestinations(
        source: (any MediaSource)?,
        resumeStore: ResumeStore,
        playbackSession: PlaybackSession,
        libraryPreferences: LibraryPreferencesStore,
        downloadManager: DownloadManager? = nil,
        downloads: DownloadObserver? = nil,
        playbackPreferences: PlaybackPreferencesStore? = nil
    ) -> some View {
        modifier(MediaNavigationDestinations(
            source: source,
            resumeStore: resumeStore,
            playbackSession: playbackSession,
            libraryPreferences: libraryPreferences,
            downloadManager: downloadManager,
            downloads: downloads,
            playbackPreferences: playbackPreferences
        ))
    }
}
