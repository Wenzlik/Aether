import Foundation
import AetherCore

/// Backs `SettingsView` with reactive state derived from `AppSession`.
///
/// Kept lightweight on purpose — Settings is a presentation surface, not its
/// own domain. The only behavior owned here is `signOut()`, which delegates
/// straight to the session and then closes the sheet so the user lands back
/// on a Home that's already re-rendered into its welcome state.
@MainActor
@Observable
final class SettingsViewModel {
    private let session: AppSession

    init(session: AppSession) {
        self.session = session
    }

    // MARK: - Account

    var isPlexSignedIn: Bool { session.isPlexSignedIn }

    var connectedServerName: String? { session.plexServer?.name }

    /// User-facing label for the Plex row in the Account section.
    var plexAccountLabel: String {
        if let name = connectedServerName { return "Connected as \(name)" }
        if isPlexSignedIn                 { return "Signed in" }
        return "Not connected"
    }

    // MARK: - Sources

    var plexSourceLabel: String {
        isPlexSignedIn ? "Connected" : "Not connected"
    }

    let synologySourceLabel = "Coming soon"

    // MARK: - Playback

    let directPlayLabel = "Available"
    let transcodingLabel = "Coming soon"
    let offlineDownloadsLabel = "Coming soon"

    // MARK: - About

    let appName = "Aether"
    let tagline = "Personal media, beautifully played."

    var versionString: String {
        infoString("CFBundleShortVersionString") ?? "—"
    }

    var buildString: String {
        infoString("CFBundleVersion") ?? "—"
    }

    private func infoString(_ key: String) -> String? {
        guard let value = Bundle.main.infoDictionary?[key] as? String, !value.isEmpty else {
            return nil
        }
        return value
    }

    // MARK: - Actions

    func signOut() async {
        await session.signOutOfPlex()
        session.isSettingsPresented = false
    }

    func dismiss() {
        session.isSettingsPresented = false
    }
}
