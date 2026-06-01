import SwiftUI
import AetherCore

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
                    onRetryDiscovery: { Task { await session.discoverPlexServers() } }
                )
            }

            Tab("Library", systemImage: "rectangle.stack.fill") {
                LibraryBrowseView(
                    source: session.source,
                    resumeStore: session.resumeStore,
                    playbackSession: session.playback,
                    libraryPreferences: session.libraryPreferences,
                    onAddSource: { session.presentSignIn() }
                )
            }

            Tab("Search", systemImage: "magnifyingglass") {
                SearchView(
                    source: session.source,
                    resumeStore: session.resumeStore,
                    playbackSession: session.playback,
                    libraryPreferences: session.libraryPreferences
                )
            }

            Tab("Settings", systemImage: "gearshape.fill") {
                SettingsView(viewModel: SettingsViewModel(session: session))
            }
        }
        .sheet(isPresented: $session.isSignInPresented) {
            PlexOnboardingView(session: session)
        }
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

    func body(content: Content) -> some View {
        content
            .navigationDestination(for: MediaItem.self) { item in
                DetailView(
                    item: item,
                    source: source,
                    resumeStore: resumeStore,
                    playbackSession: playbackSession
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
        libraryPreferences: LibraryPreferencesStore
    ) -> some View {
        modifier(MediaNavigationDestinations(
            source: source,
            resumeStore: resumeStore,
            playbackSession: playbackSession,
            libraryPreferences: libraryPreferences
        ))
    }
}
