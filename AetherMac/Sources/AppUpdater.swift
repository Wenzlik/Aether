import SwiftUI
import Combine
import Sparkle

/// In-app auto-update for the Developer ID build (#405). The Mac app ships
/// outside the App Store (bundled GPL mpv/FFmpeg), so it updates itself from the
/// website **appcast** (`SUFeedURL` in Info.plist), verifying every update
/// against the bundled EdDSA public key (`SUPublicEDKey`). The private half lives
/// in the build machine's login Keychain — see `RELEASING-macos.md`.
///
/// `SPUStandardUpdaterController` owns the whole lifecycle and the standard UI
/// (the "update available" sheet, download progress, install + relaunch). We only
/// start it, expose a "Check for Updates…" menu item, and surface the
/// automatic-check preference in Settings.
@MainActor
final class AppUpdater: ObservableObject {
    private let controller: SPUStandardUpdaterController

    /// Enables/disables the "Check for Updates…" menu item — Sparkle can't start a
    /// manual check while one is already in flight.
    @Published var canCheckForUpdates = false

    /// Mirrors Sparkle's automatic-check preference (Sparkle persists it under
    /// `SUEnableAutomaticChecks`). Bound to the Settings toggle; writes flow back
    /// to the live updater.
    @Published var automaticallyChecksForUpdates: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    init() {
        // startingUpdater: true → Sparkle runs its scheduled background checks
        // (honoring SUEnableAutomaticChecks) and is ready for manual checks.
        let controller = SPUStandardUpdaterController(startingUpdater: true,
                                                      updaterDelegate: nil,
                                                      userDriverDelegate: nil)
        self.controller = controller
        // Seed from the live value (didSet doesn't fire for this initial assign).
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() { controller.updater.checkForUpdates() }
}

/// The "Check for Updates…" menu command. A `View` so it can disable itself while
/// a check is already running (Sparkle exposes that as `canCheckForUpdates`).
struct CheckForUpdatesView: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
