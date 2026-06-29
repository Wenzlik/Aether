import SwiftUI
import AppKit
import AetherCore

/// Native macOS Aether (#232) — player-first. A single Infuse-style window:
/// sidebar (Home / Discover / Library / Search / Settings) plus an inline
/// libmpv player presented over the window when you play something. Reuses the
/// same AetherCore engines as iOS.
@main
struct AetherMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var recents = RecentsStore()
    @State private var session = MacSession()
    // In-app auto-update (#405). @StateObject so the updater (and its scheduled
    // background checks) lives for the whole app session.
    @StateObject private var updater = AppUpdater()

    var body: some Scene {
        WindowGroup {
            HomeView(session: session, recents: recents, appDelegate: appDelegate)
                .frame(minWidth: 820, minHeight: 520)
                .environment(session.watchAvailability)   // Netflix badges (#360)
                .environmentObject(updater)               // Settings ▸ About toggle (#405)
                // Returning to the app retries any SMB share that isn't mounted
                // (e.g. the NAS woke, or you're back on its network).
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { session.retryUnmountedShares() }
                }
        }
        .commands {
            // "Check for Updates…" right under "About Aether" in the app menu.
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updater)
            }
            // Real File ▸ Open… (⌘O) + Open Recent, instead of "New".
            CommandGroup(replacing: .newItem) {
                FileCommands(recents: recents, session: session)
            }
            // Menu-bar section navigation (#432). Always available — so collapsing
            // the sidebar can never strand the user with no way to switch sections.
            CommandMenu("View") {
                SectionCommands(session: session)
            }
        }

        // Native Settings window — "Aether ▸ Settings…" (⌘,).
        Settings {
            MacSettingsView(session: session)
                .tint(AetherMacTheme.accent)
                .environmentObject(updater)   // About ▸ auto-update toggle (#405)
        }
    }
}

/// Distinguishes a **launch via file open** (Finder "Open With", double-click on
/// a video when the app is closed) from opening a file while already browsing.
/// On a launch-open we want **only** the player window — the library window that
/// SwiftUI auto-creates for the primary scene should not stick around. It reopens
/// normally on the next Dock/app activation (default reopen behavior).
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    /// True from launch until shortly after the first scene settles. A launch
    /// file-open is delivered within this window; a user's later Open… is not.
    private(set) var isColdLaunch = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.isColdLaunch = false
        }
    }

    /// Forward background URLSession completion events to the download bridge so
    /// `URLSessionEventBridge.urlSessionDidFinishEvents(forBackgroundURLSession:)`
    /// can flush the OS-side completion handler — same pattern as iOS AppDelegate.
    func application(
        _ application: NSApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping @Sendable () -> Void
    ) {
        Task { @MainActor in
            BackgroundDownloadCompletions.shared.storeHandler(completionHandler, identifier: identifier)
        }
    }
}

/// File-menu items. A `View` (not raw commands) so it can use the `RecentsStore`
/// + `MacSession`. Opening a file plays it **inline in the main window** (the
/// same surface server titles use) rather than spawning a second window.
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

/// The menu-bar **View** menu: one item per section with ⌘1…⌘5, driving the same
/// `session.section` the sidebar binds to (#432). A `View` (not raw commands) so
/// it can read the session and stay in sync. Each item is a `Toggle` so the
/// active section gets a native menu checkmark; the shortcut works regardless of
/// sidebar state, which is the whole point — a collapsed sidebar never strands.
private struct SectionCommands: View {
    @Bindable var session: MacSession

    var body: some View {
        ForEach(Array(MacSession.Section.allCases.enumerated()), id: \.element) { index, section in
            Toggle(section.title, isOn: Binding(
                get: { session.section == section },
                // Only react to turning *on* — re-pressing the active section's
                // shortcut is a no-op rather than deselecting into a blank pane.
                set: { if $0 { session.section = section } }
            ))
            .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
        }
    }
}
