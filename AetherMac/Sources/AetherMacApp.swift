import SwiftUI

/// Native macOS Aether (#232) — player-first. Home is an Infuse-style shell
/// (sidebar + Recent), and opening a file spawns an IINA-style player window.
/// Reuses the same VLCKit engine as iOS; Finder file-association, play-in-place
/// bookmarks, and Plex/Jellyfin browsing are the next steps.
@main
struct AetherMacApp: App {
    @State private var recents = RecentsStore()

    var body: some Scene {
        WindowGroup {
            HomeView(recents: recents)
                .frame(minWidth: 820, minHeight: 520)
        }
        .commands {
            // Replace "New" with "Open…" — there's no document to create, the
            // verb is open-a-video.
            CommandGroup(replacing: .newItem) {}
        }

        // One player window per opened file (⌘W closes it).
        WindowGroup(for: URL.self) { $url in
            if let url {
                MacPlayerView(url: url)
                    .frame(minWidth: 640, minHeight: 400)
            }
        }
    }
}
