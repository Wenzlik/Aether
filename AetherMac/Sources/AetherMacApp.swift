import SwiftUI
import AppKit

/// Native macOS Aether (#232) — player-first. Home is an Infuse-style shell
/// (sidebar + Recent), and opening a file spawns the right player window
/// (AVPlayer for native formats, VLCKit for mkv/DTS). Reuses the same engines
/// as iOS; Plex/Jellyfin browsing is the next step.
@main
struct AetherMacApp: App {
    @State private var recents = RecentsStore()
    @State private var session = MacSession()

    var body: some Scene {
        WindowGroup {
            HomeView(session: session, recents: recents)
                .frame(minWidth: 820, minHeight: 520)
        }
        .commands {
            // Real File ▸ Open… (⌘O) + Open Recent, instead of "New".
            CommandGroup(replacing: .newItem) {
                FileCommands(recents: recents)
            }
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

/// File-menu items. A `View` (not raw commands) so it can use `openWindow` +
/// `RecentsStore` — menu-bar views still get the environment.
private struct FileCommands: View {
    var recents: RecentsStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open…") { runOpenPanel() }
            .keyboardShortcut("o")

        Menu("Open Recent") {
            ForEach(recents.urls, id: \.self) { url in
                Button(url.lastPathComponent) { open(url) }
            }
        }
        .disabled(recents.urls.isEmpty)
    }

    private func runOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = HomeView.videoTypes
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    private func open(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        recents.add(url)
        openWindow(value: url)
    }
}
