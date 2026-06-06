import Foundation
import AetherCore

/// Backs `SettingsView` with reactive state derived from `AppSession`.
///
/// Kept lightweight on purpose — Settings is a presentation surface, not its
/// own domain. It owns two behaviours: `signOut()` (delegates to the session,
/// which resets Home to its welcome state) and `connect()` (opens the sign-in
/// sheet). Settings is a full-screen tab now, so there's no sheet to dismiss.
@MainActor
@Observable
final class SettingsViewModel {
    private let session: AppSession

    init(session: AppSession) {
        self.session = session
    }

    // MARK: - Stores (exposed for direct SwiftUI binding)

    /// The app-wide playback defaults store. Exposed straight through so
    /// SettingsView can `@Bindable` it and the picker writes propagate
    /// without round-tripping through the view model.
    var playbackPreferences: PlaybackPreferencesStore { session.playbackPreferences }

    /// The app-wide appearance store (System / Dark / Light).
    var appearance: AppearancePreferenceStore { session.appearance }

    // MARK: - Account

    var isPlexSignedIn: Bool { session.isPlexSignedIn }

    var connectedServerName: String? { session.plexServer?.name }

    /// Colour-coded account state for the Account card.
    var plexAccountStatus: AetherStatus {
        if connectedServerName != nil { return .connected }
        if isPlexSignedIn             { return .positive("Signed in") }
        return .notConnected
    }

    /// Secondary line under the Plex account row when we know the server.
    var connectedServerDetail: String? {
        connectedServerName.map { "Server: \($0)" }
    }

    // MARK: - Sources

    var plexSourceStatus: AetherStatus {
        isPlexSignedIn ? .connected : .notConnected
    }

    var isJellyfinSignedIn: Bool { session.isJellyfinSignedIn }

    var jellyfinServerName: String? { session.jellyfinServer?.serverName }

    var jellyfinSourceStatus: AetherStatus {
        isJellyfinSignedIn ? .connected : .notConnected
    }

    let synologyStatus: AetherStatus = .comingSoon

    // MARK: - Active source

    /// Whether the given source is the one currently being browsed. Only
    /// meaningful when more than one source is connected.
    func isActiveSource(_ kind: AppSession.SourceKind) -> Bool {
        session.activeSourceKind == kind
    }

    /// True when both sources are connected, so the UI offers a switch.
    var canSwitchSources: Bool {
        isPlexSignedIn && isJellyfinSignedIn
    }

    func setActive(_ kind: AppSession.SourceKind) {
        session.setActiveSource(kind)
    }

    // MARK: - About

    let appName = "Aether"
    let tagline = "Personal media, beautifully played."

    var versionString: String {
        infoString("CFBundleShortVersionString") ?? "—"
    }

    var buildString: String {
        infoString("CFBundleVersion") ?? "—"
    }

    /// One-line label for the About section's tappable Version row.
    /// "Version 0.3.2 (1)" — collapses two rows (version + build) into one.
    var versionRowLabel: String {
        "Version \(versionString) (\(buildString))"
    }

    /// Codename for the current release, shown in the What's New modal. Theme:
    /// constellations, alphabetical per release (see AGENTS.md → Release
    /// process). Update this when `MARKETING_VERSION` bumps to a new version.
    let releaseCodename = "Boötes"

    /// Headline features shipped to date, surfaced in the About section's
    /// "What's New" disclosure. Cumulative — the section showcases what
    /// Aether actually does today rather than churning per-release notes;
    /// the full per-version log lives in `CHANGELOG.md`.
    let whatsNewBullets: [String] = [
        "Redesigned TV shows — pick a season, see its episodes, jump to Next Up",
        "Faster artwork — posters cache to memory + disk and load instantly",
        "Pull to refresh on Home, Library, and Discover",
        "Skip Intro / Skip Credits, with Auto-Play Next Episode",
        "Mark as Watched / Unwatched — synced back to your server",
        "Unified Library — one feed across every connected source",
        "Cinema mode on Apple Vision Pro"
    ]

    private func infoString(_ key: String) -> String? {
        guard let value = Bundle.main.infoDictionary?[key] as? String, !value.isEmpty else {
            return nil
        }
        return value
    }

    // MARK: - Actions

    /// Open the Plex sign-in / discovery flow.
    func connect() {
        session.presentSignIn(.plex)
    }

    /// Open the Jellyfin sign-in flow (server URL + Quick Connect).
    func connectJellyfin() {
        session.presentSignIn(.jellyfin)
    }

    /// Clear the Plex token + selected server and reset app state. Home returns
    /// to its welcome state; no app delete required.
    func signOut() async {
        await session.signOutOfPlex()
    }

    /// Disconnect Jellyfin; falls back to Plex if it's still connected.
    func signOutOfJellyfin() async {
        await session.signOutOfJellyfin()
    }
}
