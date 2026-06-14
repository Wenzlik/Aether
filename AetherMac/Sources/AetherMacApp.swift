import SwiftUI
import AppKit

/// Native macOS Aether (#232) — player-first. A single Infuse-style window:
/// sidebar (Home / Discover / Library / Search / Settings) plus an inline
/// libmpv player presented over the window when you play something. Reuses the
/// same AetherCore engines as iOS.
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

        // Dedicated player window for **ad-hoc local files** opened from disk
        // (Open… / Open Recent / Finder / drag-drop). They play in their own
        // window so they never take over the library (main) window — opening a
        // random file shouldn't swap your library out (#232 follow-up). Library
        // titles (Plex/Jellyfin) still play inline in the main window.
        WindowGroup(id: Self.localPlayerWindowID, for: URL.self) { $url in
            if let url {
                LocalPlayerWindow(url: url)
            }
        }
        .defaultSize(width: 1280, height: 720)

        // Native Settings window — "Aether ▸ Settings…" (⌘,).
        Settings {
            MacSettingsView(session: session)
        }
    }

    static let localPlayerWindowID = "local-player"
}

/// A standalone window that plays one local file via the libmpv player. No
/// session/library context — closing it just closes the window, leaving the
/// library window untouched.
private struct LocalPlayerWindow: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        MpvPlayerScreen(url: url, onClose: { dismiss() })
            .ignoresSafeArea()
            .preferredColorScheme(.dark)
            .navigationTitle(url.deletingPathExtension().lastPathComponent)
    }
}

/// File-menu items. A `View` (not raw commands) so it can use the `RecentsStore`
/// + `openWindow` — menu-bar views still get the environment. Opening a file
/// spawns the dedicated local-player window (not the inline main-window player).
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
        openWindow(id: AetherMacApp.localPlayerWindowID, value: url)
    }
}
