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
    var language: LanguagePreferenceStore { session.language }

    /// Netflix-availability opt-in + region (#360). Exposed for direct binding;
    /// the toggle / region setters below also drop the resolved-availability
    /// cache so badges re-evaluate immediately.
    var streamingPreferences: StreamingPreferencesStore { session.streamingPreferences }

    func setNetflixAvailabilityEnabled(_ on: Bool) {
        session.streamingPreferences.netflixAvailabilityEnabled = on
        session.watchAvailability.invalidate()
    }

    func setNetflixRegion(_ region: String?) {
        session.streamingPreferences.region = region
        session.watchAvailability.invalidate()
    }

    /// The region used right now (the explicit choice, else the device region) —
    /// for the disclosure row's trailing value.
    var resolvedNetflixRegion: String {
        let fallback = Locale.current.region?.identifier ?? "US"
        return session.streamingPreferences.resolvedRegion(default: fallback)
    }

    // MARK: - Account

    var isPlexSignedIn: Bool { session.isPlexSignedIn }

    var connectedServerName: String? { session.plexServer?.name }

    /// Trailing label for the Plex account row: the server name, or "N servers"
    /// when several are enabled at once (#325).
    var plexServerSummary: String? {
        let count = session.plexServers.count
        switch count {
        case 0:  return nil
        case 1:  return session.plexServers[0].name
        default: return "\(count) servers"
        }
    }

    /// Colour-coded account state for the Account card.
    var plexAccountStatus: AetherStatus {
        if connectedServerName != nil { return .connected }
        if isPlexSignedIn             { return .neutral("Signed in") }
        return .notConnected
    }

    /// Secondary line under the Plex account row when we know the server.
    var connectedServerDetail: String? {
        connectedServerName.map { "Server: \($0)" }
    }

    /// Stable ids of the currently-enabled servers — marks the toggled rows in
    /// the picker (#325).
    var enabledPlexServerIDs: Set<String> { session.enabledPlexServerIDs }

    /// Every Plex server the account can currently reach, ranked best-first.
    /// Swallows errors to `[]` — the picker just shows its empty/failed state.
    func availablePlexServers() async -> [PlexServerRecord] {
        (try? await session.availablePlexServers()) ?? []
    }

    /// Enable / disable a server in the picker (#325). The last enabled server
    /// can't be turned off — Sign Out disconnects Plex entirely.
    func setPlexServerEnabled(_ record: PlexServerRecord, enabled: Bool) async {
        await session.setPlexServerEnabled(record, enabled: enabled)
    }

    /// The currently-enabled Plex servers, primary first.
    var plexServers: [PlexServerRecord] { session.plexServers }

    /// The primary (first) enabled Plex server's id — what streams first when a
    /// title is on several servers (#325 follow-up).
    var primaryPlexServerID: String? { session.plexServers.first?.clientIdentifier }

    /// Make a server the primary streaming source.
    func setPrimaryPlexServer(_ record: PlexServerRecord) async {
        await session.setPrimaryPlexServer(record)
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

    var isEmbySignedIn: Bool { session.isEmbySignedIn }

    var embyServerName: String? { session.embyServer?.serverName }

    var embySourceStatus: AetherStatus {
        isEmbySignedIn ? .connected : .notConnected
    }

    var isSMBConnected: Bool { session.isSMBConnected }
    /// `false` when off the LAN — the share is dormant (hidden from the Library),
    /// not broken. Surfaced as an "Off network" note rather than an error (#214).
    var isSMBReachable: Bool { session.isSMBReachable }
    var smbServerName: String? { session.smbConnection?.displayName }
    /// The live SMB connection, so the folder picker can browse + seed its
    /// current folder selection.
    var smbConnection: SMBConnection? { session.smbConnection }
    /// Change which folders the connected share scans (add/remove after sign-in).
    func updateSMBRoots(_ roots: [String]) async { await session.updateSMBRoots(roots) }
    var smbHost: String? { session.smbConnection?.host }
    /// The signed-in SMB account, or `nil` for a guest share.
    var smbUsername: String? {
        guard let user = session.smbConnection?.username, !user.isEmpty else { return nil }
        return user
    }
    /// Number of folders the share is scoped to (0 = all shares scanned).
    var smbFolderCount: Int { session.smbConnection?.roots.count ?? 0 }

    /// TMDb match stats from the last SMB walk, for the Settings readout (#SMB
    /// info). `nil` until the SMB library has been browsed this session.
    func smbMatchSummary() async -> (matched: Int, total: Int)? {
        guard let source = session.smbSource else { return nil }
        return await source.matchSummary()
    }

    /// Drop the cached SMB walk + retry unmatched titles — re-matched on the next
    /// time the SMB Library is opened (hits stay cached, so it's cheap).
    func refreshSMB() async {
        await session.smbSource?.invalidate()
    }

    let synologyStatus: AetherStatus = .comingSoon

    // MARK: - Active source

    /// Whether the given source is the one currently being browsed. Only
    /// meaningful when more than one source is connected.
    func isActiveSource(_ kind: AppSession.SourceKind) -> Bool {
        session.activeSourceKind == kind
    }

    /// True when more than one primary source is connected, so the UI offers a switch.
    var canSwitchSources: Bool {
        [isPlexSignedIn, isJellyfinSignedIn, isEmbySignedIn].filter { $0 }.count > 1
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
    let releaseCodename = "Draco"

    /// Headline highlights for the **current** release, surfaced in What's New.
    /// Previous releases appear below under "Release History" (`releaseHistory`);
    /// the full per-version log lives in `CHANGELOG.md`. Update when the version
    /// bumps.
    let whatsNewBullets: [String] = [
        "Emby is here — connect your Emby server via Quick Connect, the same fast handshake as Jellyfin. Browse, search, and play alongside Plex and Jellyfin.",
        "New app icon across iPhone, iPad, Apple TV, Apple Vision Pro, and Mac.",
        "Background efficiency — VLC and AVPlayer idle less aggressively, image prefetching is rate-limited, and the resume loop pauses when Aether isn't in the foreground."
    ]

    /// Past releases, newest first — shown under "Release History" in What's New.
    /// Curated highlights; the full per-version log lives in `CHANGELOG.md`.
    let releaseHistory: [ReleaseNote] = [
        ReleaseNote(version: "0.7.7", codename: "Draco",
                    summary: "A UX polish pass — unified Detail action cluster, rotating Discover carousel, compact Library browse pills, compact source switcher, iPad native sidebar, and a batch of tvOS and iPadOS bug fixes."),
        ReleaseNote(version: "0.7.3", codename: "Draco",
                    summary: "Aether for macOS — a native Mac app (Apple Silicon) sharing the whole AetherCore stack, playing through libmpv, distributed as a notarized DMG. Watched marking now syncs across every connected source."),
        ReleaseNote(version: "0.7.0", codename: "Draco",
                    summary: "Native SMB (browse, downloads, a real player with track selection), audio-language Library filter, search by actor, rating sort, and a unified Settings."),
        ReleaseNote(version: "0.6.8", codename: "Cassiopeia",
                    summary: "The SMB source debut (browse + play a NAS over VLCKit), episode → Season / Show navigation, and tunable watched posters."),
        ReleaseNote(version: "0.6.7", codename: "Cassiopeia",
                    summary: "Title logo art on the Detail hero, Library browsing by Collections / Actors / Directors, a richer Season Detail (episode preview, season cast, Next Up), and a localized-season-title fix."),
        ReleaseNote(version: "0.6.6", codename: "Cassiopeia",
                    summary: "A tvOS-led polish pass — Infuse-style Detail hero with dense metadata, Library browsing by Genre and Year, season previews, reliable focus navigation, scrollable What's New, and an iPhone Settings fix."),
        ReleaseNote(version: "0.6.5", codename: "Cassiopeia",
                    summary: "Local Library metadata & artwork editing, richer TV seasons with named Season Details, smarter Continue Watching (in-progress episodes + true On Deck), and a more reliable Library and Discover."),
        ReleaseNote(version: "0.6.4", codename: "Cassiopeia",
                    summary: "The Local Library arrives — play media straight from the device with TMDb posters and metadata, TV episodes grouped into shows, mkv support via VLCKit, and a tidier Settings with accurate storage figures."),
        ReleaseNote(version: "0.6.3", codename: "Cassiopeia",
                    summary: "A Detail-screen layout pass with a platform-aware iPhone banner hero, calmer Settings, plus server Favorites, Cast & Crew, and an instant library on launch."),
        ReleaseNote(version: "0.6.2", codename: "Cassiopeia",
                    summary: "A denser, Infuse-inspired Detail screen — a clear action hierarchy, content ratings, genres everywhere, and richer technical details on both Plex and Jellyfin."),
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
            case .emby:     kind = "emby"
            case .smb:      kind = "smb"
            case .dlna:     kind = "dlna"
            case .mock:     kind = "mock"
            case .local:    kind = "local"
            case .external: kind = "external"
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

    /// Open the Emby sign-in flow (server URL + Quick Connect).
    func connectEmby() {
        session.presentSignIn(.emby)
    }

    func signOutOfEmby() async {
        await session.signOutOfEmby()
    }

    func connectSMB() {
        session.presentSignIn(.smb)
    }

    func signOutOfSMB() async {
        await session.signOutOfSMB()
    }

    // MARK: - Local Library

    /// Number of files imported into the on-device Local Library.
    var localItemCount: Int { session.localItemCount }

    /// Whether TMDb matching is available (a key was built in) — gates the
    /// "Re-match metadata" action.
    var isTMDbConfigured: Bool { session.isTMDbConfigured }

    // MARK: TMDb token (#214 — user fallback / override)

    /// The user's own TMDb token from Settings, or "" when unset.
    var userTMDbToken: String { session.userTMDbToken }
    /// Whether a key shipped in the build (so the UI can call the user token a
    /// "fallback" vs. the only source of posters).
    var hasBuiltInTMDbKey: Bool { session.hasBuiltInTMDbKey }

    /// Save or clear the user's TMDb token (blank clears). Rebuilds the SMB
    /// matcher + clears its misses so posters re-match on the next browse.
    func setTMDbToken(_ token: String) async { await session.setUserTMDbToken(token) }

    /// Validate a token with TMDb before saving (valid / rejected / unreachable).
    func validateTMDbToken(_ token: String) async -> TMDbClient.ValidationResult {
        await session.validateTMDbToken(token)
    }

    /// Fill in posters/details for titles imported before the key was set.
    func rematchLocalMetadata() async { await session.rematchLocalMetadata() }

    /// Copy the picked files into the Local Library store, then refresh the
    /// count so the source folds into `connectedSources`.
    func importLocalMedia(_ urls: [URL]) async {
        for url in urls {
            if let item = try? await session.localLibraryStore.importFile(at: url) {
                // Best-effort TMDb match (poster / overview) when a key is built in.
                await session.matchLocalMetadata(for: item)
            }
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
