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
                FileCommands(recents: recents, session: session)
            }
        }

        // Native Settings window — "Aether ▸ Settings…" (⌘,).
        Settings {
            MacSettingsView(session: session)
        }
    }
}

/// File-menu items. A `View` (not raw commands) so it can use the shared
/// `MacSession` + `RecentsStore` — menu-bar views still get the environment.
private struct FileCommands: View {
    var recents: RecentsStore
    var session: MacSession

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
        session.playLocal(url)
    }
}
