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

    /// Tab identity + lifted navigation paths, so re-selecting the active tab
    /// can pop its stack to the root.
    private enum AppTab: Hashable { case home, library, discover, search, settings }
    @State private var selectedTab: AppTab = .home
    @State private var homePath = NavigationPath()
    @State private var libraryPath = NavigationPath()
    @State private var discoverPath = NavigationPath()
    @State private var searchPath = NavigationPath()

    /// Selecting a tab — whether switching to it or re-tapping the current one —
    /// returns it to its **root**. A pushed Detail therefore never persists across
    /// tab changes (the bug: open a movie on Home, visit Library, come back to
    /// Home, and the Detail was still there with no clear way out), and a re-tap
    /// of the active tab acts as the iOS-standard "pop to root". Matches Apple TV
    /// / Netflix / Infuse.
    ///
    /// We clear the *destination* tab's path on the way in, so every tab is
    /// entered at its root. A plain `selection` binding only fires on a change;
    /// intercepting the setter lets us also catch the re-tap of the current tab.
    private var tabSelection: Binding<AppTab> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                switch newValue {
                case .home:     homePath = NavigationPath()
                case .library:  libraryPath = NavigationPath()
                case .discover: discoverPath = NavigationPath()
                case .search:   searchPath = NavigationPath()
                case .settings: break
                }
                selectedTab = newValue
            }
        )
    }

    var body: some View {
        TabView(selection: tabSelection) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                HomeView(
                    navigationPath: $homePath,
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
                    playbackPreferences: session.playbackPreferences,
                    connectedSources: session.connectedSources,
                    downloadStore: dlManager == nil ? nil : session.downloadStore
                )
            }

            Tab("Library", systemImage: "rectangle.stack.fill", value: AppTab.library) {
                LibraryBrowseView(
                    navigationPath: $libraryPath,
                    connectedSources: session.connectedSources,
                    downloadStore: dlManager == nil ? nil : session.downloadStore,
                    resumeStore: session.resumeStore,
                    playbackSession: session.playback,
                    libraryPreferences: session.libraryPreferences,
                    onAddSource: { session.presentSignIn() },
                    downloadManager: dlManager,
                    downloads: dlObserver,
                    playbackPreferences: session.playbackPreferences
                )
            }

            // Discover + Search are first-class on every platform now.
            Tab("Discover", systemImage: "sparkles", value: AppTab.discover) {
                DiscoverView(
                    navigationPath: $discoverPath,
                    connectedSources: session.connectedSources,
                    downloadStore: dlManager == nil ? nil : session.downloadStore,
                    resumeStore: session.resumeStore,
                    playbackSession: session.playback,
                    libraryPreferences: session.libraryPreferences,
                    downloadManager: dlManager,
                    downloads: dlObserver,
                    playbackPreferences: session.playbackPreferences
                )
            }

            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search) {
                SearchView(
                    navigationPath: $searchPath,
                    connectedSources: session.connectedSources,
                    source: session.source,
                    resumeStore: session.resumeStore,
                    playbackSession: session.playback,
                    libraryPreferences: session.libraryPreferences,
                    downloadManager: dlManager,
                    downloads: dlObserver,
                    playbackPreferences: session.playbackPreferences
                )
            }

            Tab("Settings", systemImage: "gearshape.fill", value: AppTab.settings) {
                // Downloads now lives inside Settings (→ Downloads), not a tab.
                // The download-pipeline deps are threaded in for that destination.
                SettingsView(
                    viewModel: SettingsViewModel(session: session),
                    source: session.source,
                    resumeStore: session.resumeStore,
                    playbackSession: session.playback,
                    libraryPreferences: session.libraryPreferences,
                    downloadManager: dlManager,
                    downloads: dlObserver
                )
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
    /// The single active source — still used by `LibraryView` (Library browse is
    /// single-source until the nav refactor).
    let source: (any MediaSource)?
    /// All connected sources — `DetailView` picks the connector for the shown
    /// item from these, so unified-feed items play through the right server.
    let connectedSources: [any MediaSource]
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
                    connectedSources: connectedSources,
                    resumeStore: resumeStore,
                    playbackSession: playbackSession,
                    downloadManager: downloadManager,
                    downloads: downloads,
                    playbackPreferences: playbackPreferences
                )
            }
            // Unified-feed titles (Home / Search) navigate the aggregated item so
            // Detail can show "Available Sources" + let the user switch servers.
            // Base item = the preferred source; falls back to any source.
            .navigationDestination(for: UnifiedMediaItem.self) { unified in
                if let base = unified.preferredSource?.item ?? unified.sources.first?.item {
                    DetailView(
                        item: base,
                        connectedSources: connectedSources,
                        resumeStore: resumeStore,
                        playbackSession: playbackSession,
                        downloadManager: downloadManager,
                        downloads: downloads,
                        playbackPreferences: playbackPreferences,
                        availableSources: unified.sources
                    )
                }
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
        connectedSources: [any MediaSource]? = nil,
        resumeStore: ResumeStore,
        playbackSession: PlaybackSession,
        libraryPreferences: LibraryPreferencesStore,
        downloadManager: DownloadManager? = nil,
        downloads: DownloadObserver? = nil,
        playbackPreferences: PlaybackPreferencesStore? = nil
    ) -> some View {
        modifier(MediaNavigationDestinations(
            source: source,
            // Default to just the active source when a caller hasn't adopted the
            // unified set yet (single-source contexts like Library / Discover).
            connectedSources: connectedSources ?? [source].compactMap { $0 },
            resumeStore: resumeStore,
            playbackSession: playbackSession,
            libraryPreferences: libraryPreferences,
            downloadManager: downloadManager,
            downloads: downloads,
            playbackPreferences: playbackPreferences
        ))
    }
}
