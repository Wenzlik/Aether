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

    /// The default cinema screen-size store (visionOS). Exposed so the Settings
    /// picker can bind to it.
    var cinemaPreferences: CinemaPreferencesStore { session.cinemaPreferences }

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

    /// Short git commit the build was cut from, stamped into the Info.plist by
    /// the "Stamp git commit" build phase. This is the *clear build identifier*:
    /// `CFBundleVersion` is only meaningful on Xcode Cloud archives (it injects
    /// `$CI_BUILD_NUMBER`) — every local Xcode build just shows "1". `nil` when
    /// the stamp didn't run (key absent / placeholder).
    var commitString: String? {
        // "dev" / "dev+" is the placeholder the stamp falls back to when git is
        // unavailable — treat any dev-prefixed value as "no stamp".
        guard let commit = infoString("AetherGitCommit"), !commit.hasPrefix("dev") else { return nil }
        return commit
    }

    /// One-line label for the About section's tappable Version row.
    /// "Version 0.5.1 (a1b2c3d)" — prefers the commit hash (works everywhere),
    /// falling back to the build number when the commit stamp is unavailable.
    var versionRowLabel: String {
        "Version \(versionString) (\(commitString ?? buildString))"
    }

    /// Codename for the current release, shown in the What's New modal. Theme:
    /// constellations, alphabetical per release (see AGENTS.md → Release
    /// process). Update this when `MARKETING_VERSION` bumps to a new version.
    let releaseCodename = "Cassiopeia"

    /// Headline highlights for the **current** release, surfaced in What's New.
    /// Previous releases appear below under "Release History" (`releaseHistory`);
    /// the full per-version log lives in `CHANGELOG.md`. Update when the version
    /// bumps.
    let whatsNewBullets: [String] = [
        "A new Support hub — report a bug or request a feature right from Settings",
        "Send Diagnostics — email a readable, private app report (no account details)",
        "A dedicated Diagnostics screen — sources, library, downloads and cache at a glance",
        "Cinema preferences on Apple Vision Pro — default screen size, seat, auto-enter and remember-last",
        "A warmer, more intimate screening room in Cinema mode",
        "An About screen, clearer setting descriptions, and a System theme option"
    ]

    /// Past releases, newest first — shown under "Release History" in What's New.
    /// Curated highlights; the full per-version log lives in `CHANGELOG.md`.
    let releaseHistory: [ReleaseNote] = [
        ReleaseNote(version: "0.6.1", codename: "Cassiopeia",
                    summary: "Settings & product-experience polish — a Support hub, Cinema preferences, diagnostics, and About."),
        ReleaseNote(version: "0.6.0", codename: "Cassiopeia",
                    summary: "A cinematic UX refresh across every platform — premium blue identity, layered backgrounds, calmer focus."),
        ReleaseNote(version: "0.5.0", codename: "Cinema",
                    summary: "Cinema Mode on Apple Vision Pro — a premium dark screening room with the screen docked in an immersive space."),
        ReleaseNote(version: "0.4.5", codename: nil,
                    summary: "Unified Library — Plex and Jellyfin titles deduplicated into one collection."),
        ReleaseNote(version: "0.3.0", codename: nil,
                    summary: "Offline downloads with background transfers and resume recovery."),
    ]

    private func infoString(_ key: String) -> String? {
        guard let value = Bundle.main.infoDictionary?[key] as? String, !value.isEmpty else {
            return nil
        }
        return value
    }

    // MARK: - Diagnostics

    /// Gather a token-free snapshot of app state for the Diagnostics screen and
    /// the "Send Diagnostics" email. Async — library counts come off the
    /// `UnifiedLibrary` actor and the image-cache size scans the cache dir.
    func gatherDiagnostics() async -> DiagnosticsSnapshot {
        let library = session.makeUnifiedLibrary()
        // Movies + shows are independent — count them concurrently.
        async let movies = library.unifiedItems(kind: .movie).count
        async let shows = library.unifiedItems(kind: .show).count
        let movieCount = await movies
        let showCount = await shows
        let downloadCount = await session.downloadStore?.snapshot().completed.count ?? 0
        let downloadBytes = await session.downloadStore?.totalCompletedSizeBytes() ?? 0
        let imageCacheBytes = await Task.detached { Int64(AetherImageCache.shared.diskUsageBytes()) }.value

        // Source rows carry only the *kind* + friendly display name — NEVER the
        // server URL / host that `MediaSourceID.stableKey` embeds (keeps the
        // snapshot token-free). "Signed in" reflects what we actually know
        // (the source is configured), not a live reachability probe.
        let sources = session.connectedSources.enumerated().map { index, source -> DiagnosticsSnapshot.SourceLine in
            let kind: String
            switch source.id {
            case .plex:     kind = "plex"
            case .jellyfin: kind = "jellyfin"
            case .synology: kind = "synology"
            case .mock:     kind = "mock"
            case .local:    kind = "local"
            }
            return DiagnosticsSnapshot.SourceLine(id: "\(kind)-\(index)", name: source.displayName, status: "Signed in")
        }

        let prefs = session.playbackPreferences
        let audio: String = {
            guard let code = prefs.defaultAudioLanguage, !code.isEmpty else { return "Source default" }
            return PlaybackLanguage.displayName(for: code)
        }()
        let subtitle: String = {
            guard let code = prefs.defaultSubtitleLanguage, !code.isEmpty else { return "Source default" }
            return code == "off" ? "Off" : PlaybackLanguage.displayName(for: code)
        }()

        return DiagnosticsSnapshot(
            appVersion: SupportDiagnostics.appVersion,
            buildNumber: SupportDiagnostics.buildNumber,
            commit: SupportDiagnostics.commit,
            platform: SupportDiagnostics.platformName,
            deviceModel: SupportDiagnostics.deviceModel(),
            osVersion: SupportDiagnostics.osVersion,
            theme: appearance.preference.displayName,
            sources: sources,
            movieCount: movieCount,
            showCount: showCount,
            downloadCount: downloadCount,
            downloadBytes: downloadBytes,
            imageCacheBytes: imageCacheBytes,
            audioPreference: audio,
            subtitlePreference: subtitle,
            generatedAt: Date()
        )
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

    // MARK: - Local Library

    /// Number of files imported into the on-device Local Library.
    var localItemCount: Int { session.localItemCount }

    /// Copy the picked files into the Local Library store, then refresh the
    /// count so the source folds into `connectedSources`.
    func importLocalMedia(_ urls: [URL]) async {
        for url in urls {
            _ = try? await session.localLibraryStore.importFile(at: url)
        }
        await session.refreshLocalLibrary()
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

/// One past release, shown in the What's New "Release History" list.
struct ReleaseNote: Identifiable, Sendable {
    var id: String { version }
    let version: String
    let codename: String?
    let summary: String
}
