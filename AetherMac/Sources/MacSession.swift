import SwiftUI
import AetherCore
import Network

/// The macOS app session — reuses AetherCore's source/auth layer to sign into
/// Plex + Jellyfin, expose the connected sources for browsing, and resolve a
/// playable URL for a tapped item. The Mac has its own Keychain namespace
/// (`cz.zmrhal.aether.mac`), so sign-in is independent of the iOS app.
@MainActor
@Observable
final class MacSession {
    private let api: any APIClient = URLSessionAPIClient()
    private let keychain = KeychainStore(service: "cz.zmrhal.aether.mac")

    private let plexConfiguration: PlexConfiguration
    private let jellyfinConfiguration: JellyfinConfiguration
    private let embyConfiguration: EmbyConfiguration
    let plexAuthClient: PlexAuthClient
    let plexHomeClient: PlexHomeClient
    let jellyfinAuthClient: JellyfinAuthClient
    let embyAuthClient: EmbyAuthClient
    private let plexResourceClient: PlexResourceClient
    private let plexServerStore: PlexServerStore
    private let jellyfinServerStore: JellyfinServerStore
    private let embyServerStore: EmbyServerStore
    private let smbShareStore: SMBShareStore

    private(set) var plexSources: [PlexMediaSource] = []
    /// The enabled Plex servers, primary first — kept so the Settings server
    /// picker can reorder them (#325). Mirrors `plexSources`.
    private(set) var plexServerRecords: [PlexServerRecord] = []
    /// The active Plex Home profile, when the account has Home and a profile was
    /// picked. `nil` for plain accounts. Drives the Settings "Switch Profile" UI.
    private(set) var activePlexUser: PlexHomeUserRef?
    /// All connected Jellyfin / Emby servers + their live sources (multi-server,
    /// parity with iOS). `jellyfinSource`/`embySource` are `.first` conveniences.
    private(set) var jellyfinServers: [JellyfinServerRecord] = []
    private(set) var jellyfinSources: [JellyfinMediaSource] = []
    var jellyfinSource: JellyfinMediaSource? { jellyfinSources.first }
    private(set) var embyServers: [EmbyServerRecord] = []
    private(set) var embySources: [EmbyMediaSource] = []
    var embySource: EmbyMediaSource? { embySources.first }

    /// User-picked local/network folders scanned into a library, and the source
    /// built from them. Folders persist as paths in UserDefaults.
    private(set) var localFolders: [URL] = MacSession.loadLocalFolders()
    private var localSource: LocalFolderSource?

    /// Configured SMB shares (persisted in the Keychain), the live mountpoint
    /// each one resolved to once mounted, and any per-share mount error to show
    /// in Settings. macOS mounts shares via NetFS and folds their mountpoints
    /// into the same `LocalFolderSource` scan as local folders — see
    /// `SMBMounter` / `SMBShare` for why the Mac doesn't need iOS's SMB stack.
    private(set) var smbShares: [SMBShare] = []
    private var smbMountpoints: [UUID: URL] = [:]
    private(set) var smbMountErrors: [UUID: String] = [:]
    /// Shares whose mount is currently in flight — `NetFSMountURLSync` can take
    /// up to the timeout, so this guards against a network/foreground retry
    /// stacking a second attempt on top of one already running.
    private var smbMountsInFlight: Set<UUID> = []
    /// Watches for network changes (getting home, VPN up) to auto-remount shares
    /// that aren't mounted yet — so a NAS that was unreachable at launch comes
    /// online without the user hitting Reconnect by hand.
    private let smbPathMonitor = NWPathMonitor()
    private var smbPathMonitorStarted = false

    /// Per-folder content hint (Movies / TV / Both) for user-picked local
    /// folders, keyed by path. Drives `SMBFolderClassifier` via
    /// `LocalFolderSource`; missing → `.both`. Persisted in UserDefaults.
    private(set) var localFolderContent: [String: SMBRootContent] = MacSession.loadLocalFolderContent()

    /// Every folder fed into the local-library scan: user-picked folders plus
    /// the mountpoints of currently-mounted SMB shares.
    private var scanFolders: [URL] { localFolders + Array(smbMountpoints.values) }

    /// Content hint per scan folder, combining local-folder choices with each
    /// mounted SMB share's choice (keyed by the share's mountpoint URL).
    private var folderContentMap: [URL: SMBRootContent] {
        var map: [URL: SMBRootContent] = [:]
        for url in localFolders {
            if let c = localFolderContent[url.path] { map[url] = c }
        }
        for share in smbShares {
            if let mountpoint = smbMountpoints[share.id] { map[mountpoint] = share.contentChoice }
        }
        return map
    }

    /// Bumped whenever the set of sources or local folders changes, so the
    /// library/discover views reload (their `.task(id:)` keys on it). Needed
    /// because adding a 2nd folder doesn't change `connectedSources.count`.
    private(set) var libraryToken = 0

    /// Human status of the local-library scan, shown in Settings: `"Scanning…"`
    /// then e.g. `"42 movies · 8 shows"`. `nil` when no folders are configured.
    private(set) var localScanStatus: String?

    /// Server display names, mirrored as plain strings for the Settings UI —
    /// the source objects are actors, so their `displayName` can't be read from
    /// the main actor synchronously.
    private(set) var plexServerNames: [String] = []
    private(set) var jellyfinServerName: String?
    private(set) var embyServerName: String?

    /// App-wide display + playback defaults, shared with the iOS app's model.
    /// On Mac we wire the ones that affect what's on screen: the watched-poster
    /// treatment (`\.watchedDisplay`) and hide-watched-in-discovery.
    let playbackPrefs = PlaybackPreferencesStore()

    /// Colour-scheme preference (System / Dark / Light), same store the iOS app
    /// uses — drives `.preferredColorScheme` at the window root so the Appearance
    /// setting actually switches the theme instead of being forced dark.
    let appearance = AppearancePreferenceStore()

    // MARK: - Downloads

    /// Persistent job store. Created async (loads from disk) in `restore()`.
    private var downloadStore: DownloadStore?

    /// URLSession-backed download engine. Created in `restore()` after the store
    /// is ready. `nil` until then — views check `downloadManager != nil` before
    /// showing download controls. Uses `~/Movies/Aether/` as the save directory.
    private(set) var downloadManager: DownloadManager?

    /// SwiftUI mirror of the store. `nil` until `restore()` initialises the store;
    /// once set it is permanent for the lifetime of the session.
    private(set) var downloadObserver: DownloadObserver?

    /// `~/Movies/Aether/` — user-visible, survives uninstall, easy to browse in
    /// Finder. Uses `.moviesDirectory` which resolves to the user's Movies folder.
    static func downloadsDirectory() -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Movies")
        return movies.appendingPathComponent("Aether", isDirectory: true)
    }

    /// Whether this item can be downloaded (source connected + source supports it).
    func canDownload(_ item: MediaItem) -> Bool {
        guard downloadManager != nil else { return false }
        return source(for: item)?.supportsDownloads == true
    }

    /// The current download status for an item — `.notDownloaded` when the
    /// observer isn't ready yet (before `restore()` completes).
    func downloadStatus(for item: MediaItem) -> DownloadStatus {
        downloadObserver?.status(for: item.id) ?? .notDownloaded
    }

    /// Enqueue a download. No-op if the source doesn't support downloads or the
    /// manager hasn't initialised yet.
    func download(_ item: MediaItem, quality: PlaybackQuality) {
        guard let manager = downloadManager, let src = source(for: item) else { return }
        Task { try? await manager.enqueue(item: item, source: src, quality: quality) }
    }

    func pauseDownload(_ jobID: UUID) {
        Task { await downloadManager?.pause(jobID) }
    }

    func resumeDownload(_ jobID: UUID) {
        Task { await downloadManager?.resume(jobID) }
    }

    func cancelDownload(_ jobID: UUID) {
        Task { await downloadManager?.cancel(jobID) }
    }

    func removeDownload(_ jobID: UUID) {
        Task { await downloadManager?.remove(jobID) }
    }

    // MARK: - Navigation (#432)

    /// A top-level section of the app. Single source of truth for both the
    /// sidebar row labels/symbols and the menu-bar **View** commands, so the two
    /// can never drift apart.
    enum Section: String, CaseIterable, Identifiable, Hashable {
        // Search is intentionally NOT a section — it's a field at the top of the
        // sidebar (Infuse-style); typing surfaces results over the current pane.
        case home, discover, library
        var id: Self { self }

        var title: String {
            switch self {
            case .home:     "Home"
            case .discover: "Discover"
            case .library:  "Library"
            }
        }

        var symbol: String {
            switch self {
            case .home:     "house"
            case .discover: "sparkles"
            case .library:  "square.grid.2x2"
            }
        }
    }

    /// The selected section. **Hoisted onto the session** (off `ContentView`'s
    /// former local `@State`) so the menu-bar View commands + ⌘1…⌘5 can switch
    /// sections even when the sidebar is collapsed — collapsing it used to strand
    /// the user with no other way to navigate (#432).
    var section: Section = .home

    /// UI language: `"system"`, `"en"`, or `"cs"`. Drives `\.locale` so the user
    /// can switch in-app (Settings), matching iOS. Persisted in UserDefaults.
    var appLanguage: String = UserDefaults.standard.string(forKey: "ui.language") ?? "system" {
        didSet { UserDefaults.standard.set(appLanguage, forKey: "ui.language") }
    }
    /// The locale to inject, or `nil` to follow the system language.
    var appLocale: Locale { appLanguage == "system" ? .autoupdatingCurrent : Locale(identifier: appLanguage) }

    /// Manual TMDb API key override (Settings). Empty = use the build-injected
    /// key (Info.plist `TMDBAPIKey`, like iOS). Drives local-library metadata
    /// matching (posters/overviews); changing it rescans the local library.
    var tmdbToken: String = UserDefaults.standard.string(forKey: "tmdb.token") ?? "" {
        // Only persist on edit — do NOT rebuild the library on every keystroke
        // (that bumped libraryToken per character and made the field unusable).
        // The new key is applied on the next rescan (Rescan button / field submit).
        didSet { UserDefaults.standard.set(tmdbToken, forKey: "tmdb.token") }
    }
    /// Manual override if set, else the key baked in at build time.
    private var effectiveTMDBKey: String {
        let manual = tmdbToken.trimmingCharacters(in: .whitespaces)
        if !manual.isEmpty { return manual }
        return (Bundle.main.object(forInfoDictionaryKey: "TMDBAPIKey") as? String) ?? ""
    }
    var isTMDBConfigured: Bool { !effectiveTMDBKey.isEmpty }
    private func makeTMDbClient() -> TMDbClient? {
        let key = effectiveTMDBKey
        return key.isEmpty ? nil : TMDbClient(apiKey: key, api: api)
    }

    /// A configured TMDb client for Ask Aether's "more like this" + keyword
    /// grounding; `nil` when no key is set.
    var tmdbClient: TMDbClient? { makeTMDbClient() }

    /// Verify a TMDb key against the API (`/authentication`) before saving it, so
    /// Settings can confirm it's valid and only then store + hide it.
    func validateTMDbKey(_ key: String) async -> TMDbClient.ValidationResult {
        await TMDbClient(apiKey: key.trimmingCharacters(in: .whitespacesAndNewlines), api: api).validate()
    }

    /// Fetch TMDb `vote_average` by ID — used by Detail to show the TMDb rating
    /// alongside the server community rating. Best-effort: `nil` on any failure.
    func fetchTMDbRating(tmdbID: Int, type: TMDbClient.MediaType) async -> Double? {
        guard let client = makeTMDbClient() else { return nil }
        return await client.details(tmdbID: tmdbID, type: type)?.rating
    }

    /// Search TMDb candidates by title — used by the Fix Match sheet to let the
    /// user correct a wrong or missing automatic match for a local library item.
    func searchTMDb(title: String, year: Int?, isEpisode: Bool) async -> [TMDbMetadata] {
        guard let client = makeTMDbClient() else { return [] }
        return await client.searchCandidates(title: title, year: year, isEpisode: isEpisode)
    }

    /// Persist a manual TMDb match for a local library item and refresh the
    /// library token so all views reload with the new metadata.
    func applyLocalTMDbMatch(_ meta: TMDbMetadata, to item: MediaItem) async {
        await localSource?.applyTMDbOverride(meta, for: item.id)
        libraryToken &+= 1
    }

    // MARK: - Netflix availability (#360)

    /// Opt-in Netflix-availability prefs (toggle + region), shared store with iOS.
    let streamingPreferences = StreamingPreferencesStore()

    /// Shared 24h cache so the badge store + every Discover/Search lookup hit the
    /// same warm entries.
    private let watchProvidersCache = WatchProvidersService.Cache()

    /// A service over the current TMDb key + resolved region, or nil with no key.
    /// Region is the user's Settings choice, else the device region (availability
    /// is about where you physically are, not the UI language).
    func makeWatchProvidersService() -> WatchProvidersService? {
        guard isTMDBConfigured else { return nil }
        let fallback = Locale.current.region?.identifier ?? "US"
        let region = streamingPreferences.resolvedRegion(default: fallback)
        return WatchProvidersService(apiKey: effectiveTMDBKey, api: api, region: region, cache: watchProvidersCache)
    }

    /// `@MainActor`-bound badge store views read synchronously (see iOS).
    @ObservationIgnored
    private(set) lazy var watchAvailability = WatchAvailabilityStore(
        preferences: streamingPreferences,
        makeService: { [weak self] in self?.makeWatchProvidersService() }
    )

    var isPlexConnected: Bool { !plexSources.isEmpty }
    var isJellyfinConnected: Bool { jellyfinSource != nil }
    var isEmbyConnected: Bool { embySource != nil }
    var isSMBConnected: Bool { !smbShares.isEmpty }
    var hasAnySource: Bool { isPlexConnected || isJellyfinConnected || isEmbyConnected || !localFolders.isEmpty || isSMBConnected }

    /// Every connected source — what `UnifiedLibrary` fans out over.
    var connectedSources: [any MediaSource] {
        var list: [any MediaSource] = []
        list.append(contentsOf: plexSources)
        list.append(contentsOf: jellyfinSources)
        list.append(contentsOf: embySources)
        if let localSource { list.append(localSource) }
        return list
    }

    // MARK: Local library (folder scan)

    private static let localFoldersKey = "local.folders"
    private static let localFolderContentKey = "local.folderContent"
    private static func loadLocalFolders() -> [URL] {
        (UserDefaults.standard.stringArray(forKey: localFoldersKey) ?? []).map { URL(fileURLWithPath: $0) }
    }
    private static func loadLocalFolderContent() -> [String: SMBRootContent] {
        guard let data = UserDefaults.standard.data(forKey: localFolderContentKey),
              let decoded = try? JSONDecoder().decode([String: SMBRootContent].self, from: data) else { return [:] }
        return decoded
    }

    /// Add a folder to the local library and rescan.
    func addLocalFolder(_ url: URL) {
        guard !localFolders.contains(url) else { return }
        _ = url.startAccessingSecurityScopedResource()
        localFolders.append(url)
        persistLocalFolders()
    }

    func removeLocalFolder(_ url: URL) {
        localFolders.removeAll { $0 == url }
        localFolderContent[url.path] = nil
        persistLocalFolderContent()
        persistLocalFolders()
    }

    /// Set what a local folder holds (Movies / TV / Both) and rescan.
    func setLocalFolderContent(_ url: URL, _ content: SMBRootContent) {
        localFolderContent[url.path] = content
        persistLocalFolderContent()
        rebuildLocalSource()
    }

    private func persistLocalFolderContent() {
        if let data = try? JSONEncoder().encode(localFolderContent) {
            UserDefaults.standard.set(data, forKey: Self.localFolderContentKey)
        }
    }

    /// Re-scan the local folders (picks up files added/removed on disk and a
    /// changed TMDb key) by rebuilding the source with a fresh cache.
    func rescanLocalLibrary() { rebuildLocalSource() }

    private func persistLocalFolders() {
        UserDefaults.standard.set(localFolders.map(\.path), forKey: Self.localFoldersKey)
        rebuildLocalSource()
    }

    private func rebuildLocalSource() {
        let folders = scanFolders
        guard !folders.isEmpty else {
            localSource = nil
            localScanStatus = nil
            libraryToken &+= 1
            return
        }
        let source = LocalFolderSource(folders: folders, content: folderContentMap, tmdb: makeTMDbClient())
        localSource = source
        libraryToken &+= 1
        // Scan in the background and report progress → result in Settings.
        localScanStatus = "Scanning…"
        Task { [weak self] in
            let (movies, shows) = await source.counts()
            guard self?.localSource === source else { return }   // superseded by a newer scan
            if movies == 0 && shows == 0 {
                self?.localScanStatus = "No movies or shows found"
            } else {
                var parts: [String] = []
                if movies > 0 { parts.append("\(movies) \(movies == 1 ? "movie" : "movies")") }
                if shows > 0 { parts.append("\(shows) \(shows == 1 ? "show" : "shows")") }
                self?.localScanStatus = parts.joined(separator: " · ")
            }
        }
    }

    private static let plexTokenKey = "plex.authToken"
    private static let plexAdminTokenKey = "plex.adminToken"
    /// Additional Plex account tokens beyond the primary, as a JSON string array.
    private static let plexExtraAccountTokensKey = "plex.extraAccountTokens"
    private static let plexHomeUserKey = "plex.homeUser"
    private static let plexClientIDKey = "plex.clientIdentifier"
    private static let jellyfinDeviceIDKey = "jellyfin.deviceID"
    private static let embyDeviceIDKey = "emby.deviceID"

    init() {
        let clientID = Self.persistentID(Self.plexClientIDKey)
        let deviceID = Self.persistentID(Self.jellyfinDeviceIDKey)
        let embyDeviceID = Self.persistentID(Self.embyDeviceIDKey)
        let host = Host.current().localizedName ?? "Mac"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

        // Identify to Plex as **iOS**, not macOS: Plex's universal transcoder
        // picks a profile from `X-Plex-Platform`, and "macOS" makes its decision
        // endpoint reject the transcode with HTTP 400. The Mac's Plex playback is
        // functionally iOS (AVKit/HLS via AVPlayer), so the iOS profile fits —
        // the same workaround the iOS app uses for visionOS. `deviceName` stays
        // the real Mac name, so Plex's device list still shows the hardware.
        plexConfiguration = PlexConfiguration(
            product: "Aether", version: "0.7.2", clientIdentifier: clientID,
            deviceName: host, platform: "iOS", platformVersion: osVersion
        )
        jellyfinConfiguration = JellyfinConfiguration(
            client: "Aether", version: "0.7.2", deviceName: host, deviceID: deviceID
        )
        embyConfiguration = EmbyConfiguration(
            client: "Aether", version: "0.7.2", deviceName: host, deviceID: embyDeviceID
        )
        plexAuthClient = PlexAuthClient(api: api, configuration: plexConfiguration)
        plexHomeClient = PlexHomeClient(api: api, configuration: plexConfiguration)
        jellyfinAuthClient = JellyfinAuthClient(api: api, configuration: jellyfinConfiguration)
        embyAuthClient = EmbyAuthClient(api: api, configuration: embyConfiguration)
        plexResourceClient = PlexResourceClient(api: api, configuration: plexConfiguration)
        plexServerStore = PlexServerStore(keychain: keychain)
        jellyfinServerStore = JellyfinServerStore(keychain: keychain)
        embyServerStore = EmbyServerStore(keychain: keychain)
        smbShareStore = SMBShareStore(keychain: keychain)
    }

    // MARK: Restore

    /// Whether `restore()` has finished wiring up persisted sources. Views use
    /// it to keep showing a loading state during startup instead of flashing the
    /// "connect a source" empty state before the keychain/store reads complete.
    private(set) var didRestore = false

    func restore() async {
        // Guard against re-running when the library view reappears after the
        // player closes (the player replaces it, so `.task` would fire again).
        guard !didRestore else { return }
        didRestore = true
        await resumeStore.loadFromDisk()
        rebuildLocalSource()    // build the local library from persisted folders
        if let records = try? await plexServerStore.readAll(), !records.isEmpty {
            plexServerRecords = records
            plexSources = records.map(makePlexSource)
            plexServerNames = records.map(\.name)
        }
        // Restore the active Plex Home profile (the working token was already
        // persisted, so playback resumes as that profile).
        if let json = try? await keychain.string(for: Self.plexHomeUserKey),
           let data = json.data(using: .utf8),
           let ref = try? JSONDecoder().decode(PlexHomeUserRef.self, from: data) {
            activePlexUser = ref
        }
        if let records = try? await jellyfinServerStore.readAll(), !records.isEmpty {
            jellyfinServers = records
            jellyfinSources = records.compactMap { makeJellyfinSource($0) }
            jellyfinServerName = Self.serverSummary(records.map(\.serverName))
        }
        if let records = try? await embyServerStore.readAll(), !records.isEmpty {
            embyServers = records
            embySources = records.compactMap { makeEmbySource($0) }
            embyServerName = Self.serverSummary(records.map(\.serverName))
        }
        if let shares = try? await smbShareStore.read(), !shares.isEmpty {
            smbShares = shares
            // Mount in the background — a NAS may be asleep or off-network, and
            // we must never block app startup on it. Each share that comes up
            // registers its mountpoint and rebuilds the local source, so the
            // library fills in as shares mount (or stays empty if they don't).
            for share in shares {
                Task { await mountAndRegister(share) }
            }
            // Auto-remount on network changes so an unreachable NAS comes online
            // later without a manual Reconnect.
            startSMBAutoRemount()
        }
        // Sources are wired up now — bump the token so any view that ran its
        // initial load before restore finished (Home/Discover race the library
        // window's `.task`) reloads against the freshly restored sources.
        libraryToken &+= 1
        // Spin up the download stack (store → observer → manager). Done after
        // sources are restored so recovered URLSession tasks can be attributed to
        // the now-live sources. Guard prevents re-init on player close/reopen.
        if downloadStore == nil {
            let store = await DownloadStore()
            downloadObserver = DownloadObserver(store: store)
            downloadManager = await DownloadManager(
                store: store,
                downloadsDirectory: MacSession.downloadsDirectory()
            )
            downloadStore = store
        }
    }

    // MARK: Plex

    /// Called with the `PlexSignInResult` from `PlexSignInViewModel`'s `.success`
    /// (working token = the picked Plex Home profile's scoped token, or the
    /// account token). Persists tokens + active profile, discovers reachable
    /// servers, and builds the live sources.
    func completePlexSignIn(result: PlexSignInResult) async {
        if let primary = await plexPrimaryToken() {
            // Additional account: keep the primary (and its Home profiles) intact,
            // record this account's token so its servers appear in Manage Servers.
            var extras = await plexExtraAccountTokens()
            if result.token != primary, !extras.contains(result.token) { extras.append(result.token) }
            await setPlexExtraAccountTokens(extras)
            await discoverPlexServers(token: primary)   // refresh; extras surface in the picker
        } else {
            try? await keychain.setString(result.token, for: Self.plexTokenKey)
            try? await keychain.setString(result.adminToken, for: Self.plexAdminTokenKey)
            await persistActivePlexUser(result.user)
            await discoverPlexServers(token: result.token)
        }
    }

    // MARK: Plex accounts (multi-account, additive over the primary)

    private func plexPrimaryToken() async -> String? {
        guard let token = (try? await keychain.string(for: Self.plexTokenKey)) ?? nil, !token.isEmpty else { return nil }
        return token
    }

    private func plexExtraAccountTokens() async -> [String] {
        guard let json = (try? await keychain.string(for: Self.plexExtraAccountTokensKey)) ?? nil,
              let data = json.data(using: .utf8),
              let tokens = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return tokens
    }

    private func setPlexExtraAccountTokens(_ tokens: [String]) async {
        if tokens.isEmpty {
            try? await keychain.removeValue(for: Self.plexExtraAccountTokensKey)
            return
        }
        if let data = try? JSONEncoder().encode(tokens), let json = String(data: data, encoding: .utf8) {
            try? await keychain.setString(json, for: Self.plexExtraAccountTokensKey)
        }
    }

    private func allPlexAccountTokens() async -> [String] {
        var tokens: [String] = []
        if let primary = await plexPrimaryToken() { tokens.append(primary) }
        tokens.append(contentsOf: await plexExtraAccountTokens())
        return tokens
    }

    /// Fetch resources for `token`, pick + persist the reachable servers, build
    /// the live sources. Shared by sign-in and profile switching.
    private func discoverPlexServers(token: String) async {
        guard let resources = try? await plexResourceClient.resources(token: token) else { return }
        let records = PlexServerSelector().rankedSelections(from: resources).map { $0.makeRecord() }
        guard !records.isEmpty else { return }
        try? await plexServerStore.writeAll(records)
        plexServerRecords = records
        plexSources = records.map(makePlexSource)
        plexServerNames = records.map(\.name)
        libraryToken &+= 1
    }

    /// The Plex Home profiles on the signed-in account (for the Settings
    /// switcher). Empty when Home isn't enabled or the account token is missing.
    func plexHomeUsers() async -> [PlexAPI.HomeUser] {
        guard let admin = try? await keychain.string(for: Self.plexAdminTokenKey), !admin.isEmpty
        else { return [] }
        return (try? await plexHomeClient.users(adminToken: admin)) ?? []
    }

    /// Switch the active Plex Home profile (Settings). Swaps the working token,
    /// re-runs discovery and rebuilds sources. Throws `PlexHomeError.invalidPIN`.
    func switchPlexUser(_ user: PlexAPI.HomeUser, pin: String?) async throws {
        guard let admin = try? await keychain.string(for: Self.plexAdminTokenKey), !admin.isEmpty
        else { return }
        let token = try await plexHomeClient.switchUser(uuid: user.uuid, pin: pin, adminToken: admin)
        try? await keychain.setString(token, for: Self.plexTokenKey)
        await persistActivePlexUser(user)
        try? await plexServerStore.clear()
        plexServerRecords = []
        plexSources = []
        plexServerNames = []
        await discoverPlexServers(token: token)
    }

    /// Persist (or clear) the active Home profile ref + update the property.
    private func persistActivePlexUser(_ user: PlexAPI.HomeUser?) async {
        activePlexUser = user.map(PlexHomeUserRef.init)
        if let ref = activePlexUser,
           let data = try? JSONEncoder().encode(ref),
           let json = String(data: data, encoding: .utf8) {
            try? await keychain.setString(json, for: Self.plexHomeUserKey)
        } else {
            try? await keychain.removeValue(for: Self.plexHomeUserKey)
        }
    }

    func signOutPlex() async {
        try? await keychain.removeValue(for: Self.plexTokenKey)
        try? await keychain.removeValue(for: Self.plexAdminTokenKey)
        await setPlexExtraAccountTokens([])
        await persistActivePlexUser(nil)
        try? await plexServerStore.clear()
        plexServerRecords = []
        plexSources = []
        plexServerNames = []
        libraryToken &+= 1
    }

    /// The primary (first) Plex server's id — streams first when a title is on
    /// several servers (#325).
    var primaryPlexServerID: String? { plexServerRecords.first?.clientIdentifier }

    /// Make `record` the primary streaming server: move it to the front, persist,
    /// and rebuild the live sources so the Unified Library prefers it. No-op when
    /// it isn't enabled or is already primary.
    func setPrimaryPlexServer(_ record: PlexServerRecord) async {
        var records = plexServerRecords
        guard let index = records.firstIndex(where: { $0.clientIdentifier == record.clientIdentifier }),
              index != 0 else { return }
        let chosen = records.remove(at: index)
        records.insert(chosen, at: 0)
        try? await plexServerStore.writeAll(records)
        plexServerRecords = records
        plexSources = records.map(makePlexSource)
        plexServerNames = records.map(\.name)
        libraryToken &+= 1
    }

    /// Fetch every Plex server reachable on the signed-in account, ranked
    /// best-first by `PlexServerSelector`. Returns `nil` on network / auth
    /// failure so the caller can distinguish "error" from "no servers found".
    func loadReachablePlexServers() async -> [PlexServerRecord]? {
        let tokens = await allPlexAccountTokens()
        guard !tokens.isEmpty else { return nil }
        // Merge the servers reachable from every connected account, de-duped by
        // clientIdentifier (same server via two accounts shows once).
        var seen = Set<String>()
        var merged: [PlexServerRecord] = []
        var anySucceeded = false
        for token in tokens {
            guard let resources = try? await plexResourceClient.resources(token: token) else { continue }
            anySucceeded = true
            for record in PlexServerSelector().rankedSelections(from: resources).map({ $0.makeRecord() })
            where seen.insert(record.clientIdentifier).inserted {
                merged.append(record)
            }
        }
        return anySucceeded ? merged : nil
    }

    /// Add or remove `record` from the active streaming set. At least one server
    /// must remain enabled — disabling the last one is a no-op (sign out is the
    /// way to disconnect). Enabling an already-enabled server is also a no-op.
    func setPlexServerEnabled(_ record: PlexServerRecord, enabled: Bool) async {
        var records = plexServerRecords
        if enabled {
            guard !records.contains(where: { $0.clientIdentifier == record.clientIdentifier }) else { return }
            records.append(record)
        } else {
            guard records.count > 1 else { return }
            records.removeAll { $0.clientIdentifier == record.clientIdentifier }
        }
        try? await plexServerStore.writeAll(records)
        plexServerRecords = records
        plexSources = records.map(makePlexSource)
        plexServerNames = records.map(\.name)
        libraryToken &+= 1
    }

    private func makePlexSource(_ record: PlexServerRecord) -> PlexMediaSource {
        PlexMediaSource(
            serverID: record.clientIdentifier,
            displayName: record.name,
            accessToken: record.accessToken,
            connections: record.connections,
            configuration: plexConfiguration,
            api: api
        )
    }

    // MARK: Jellyfin

    /// Append a Jellyfin server (re-adding the same URL replaces it) — multiple
    /// servers can be connected at once.
    func completeJellyfinSignIn(_ record: JellyfinServerRecord) async {
        var records = jellyfinServers.filter { $0.baseURLString != record.baseURLString }
        records.append(record)
        jellyfinServers = records
        jellyfinSources = records.compactMap { makeJellyfinSource($0) }
        try? await jellyfinServerStore.writeAll(records)
        jellyfinServerName = Self.serverSummary(records.map(\.serverName))
        libraryToken &+= 1
    }

    /// Disconnect every Jellyfin server.
    func signOutJellyfin() async {
        try? await jellyfinServerStore.clear()
        jellyfinServers = []
        jellyfinSources = []
        jellyfinServerName = nil
        libraryToken &+= 1
    }

    /// Remove one Jellyfin server by id (`baseURLString`), keeping the others.
    func removeJellyfinServer(_ serverID: String) async {
        let records = jellyfinServers.filter { $0.baseURLString != serverID }
        if records.isEmpty { await signOutJellyfin(); return }
        jellyfinServers = records
        jellyfinSources = records.compactMap { makeJellyfinSource($0) }
        try? await jellyfinServerStore.writeAll(records)
        jellyfinServerName = Self.serverSummary(records.map(\.serverName))
        libraryToken &+= 1
    }

    /// The connected Jellyfin source whose server matches `id` (for source-scoped
    /// actions like Identify), built from the matching record. Falls back to the
    /// first connected Jellyfin source.
    func jellyfinSource(for id: MediaID) -> JellyfinMediaSource? {
        guard case let .jellyfin(serverID) = id.source,
              let record = jellyfinServers.first(where: { ($0.baseURL?.host ?? $0.baseURLString) == serverID }),
              let source = makeJellyfinSource(record) else {
            return jellyfinSource
        }
        return source
    }

    /// Drop the cached catalog after a server-side mutation made from the app
    /// (e.g. a Jellyfin identify) so surfaces re-read the fresh metadata.
    func libraryDidChangeExternally() async {
        await makeLibrary().invalidate(kinds: [.movie, .show])
        libraryToken &+= 1
    }

    /// Trailing label: the server name, or "N servers" when several are connected.
    static func serverSummary(_ names: [String]) -> String? {
        switch names.count {
        case 0:  return nil
        case 1:  return names[0]
        default: return "\(names.count) servers"
        }
    }

    private func makeJellyfinSource(_ record: JellyfinServerRecord) -> JellyfinMediaSource? {
        guard let baseURL = record.baseURL else { return nil }
        return JellyfinMediaSource(
            serverID: baseURL.host ?? record.baseURLString,
            displayName: record.serverName,
            baseURL: baseURL,
            accessToken: record.accessToken,
            userID: record.userID,
            configuration: jellyfinConfiguration,
            api: api
        )
    }

    // MARK: Emby

    /// Append an Emby server (re-adding the same URL replaces it).
    func completeEmbySignIn(_ record: EmbyServerRecord) async {
        var records = embyServers.filter { $0.baseURLString != record.baseURLString }
        records.append(record)
        embyServers = records
        embySources = records.compactMap { makeEmbySource($0) }
        try? await embyServerStore.writeAll(records)
        embyServerName = Self.serverSummary(records.map(\.serverName))
        libraryToken &+= 1
    }

    /// Disconnect every Emby server.
    func signOutEmby() async {
        try? await embyServerStore.clear()
        embyServers = []
        embySources = []
        embyServerName = nil
        libraryToken &+= 1
    }

    /// Remove one Emby server by id (`baseURLString`), keeping the others.
    func removeEmbyServer(_ serverID: String) async {
        let records = embyServers.filter { $0.baseURLString != serverID }
        if records.isEmpty { await signOutEmby(); return }
        embyServers = records
        embySources = records.compactMap { makeEmbySource($0) }
        try? await embyServerStore.writeAll(records)
        embyServerName = Self.serverSummary(records.map(\.serverName))
        libraryToken &+= 1
    }

    private func makeEmbySource(_ record: EmbyServerRecord) -> EmbyMediaSource? {
        guard let baseURL = record.baseURL else { return nil }
        return EmbyMediaSource(
            serverID: baseURL.host ?? record.baseURLString,
            displayName: record.serverName,
            baseURL: baseURL,
            accessToken: record.accessToken,
            userID: record.userID,
            configuration: embyConfiguration,
            api: api
        )
    }

    // MARK: SMB shares

    /// Add an SMB share: mount it first (so we validate the server + credentials
    /// before saving anything), then persist and fold its mountpoint into the
    /// local-library scan. Returns a user-facing error message on failure, or
    /// `nil` on success. Nothing is persisted if the mount fails.
    func addSMBShare(host: String, shareName: String, username: String?, password: String?,
                     content: SMBRootContent = .both) async -> String? {
        let host = host.trimmingCharacters(in: .whitespaces)
        let shareName = shareName.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        guard !host.isEmpty, !shareName.isEmpty else {
            return String(localized: "Enter both a server and a share name.")
        }
        // Avoid duplicates — same host + share already configured.
        if smbShares.contains(where: { $0.host.caseInsensitiveCompare(host) == .orderedSame
            && $0.shareName.caseInsensitiveCompare(shareName) == .orderedSame }) {
            return String(localized: "That share is already added.")
        }
        let share = SMBShare(host: host, shareName: shareName, username: username,
                             password: password, content: content)
        do {
            let mountpoint = try await SMBMounter.mount(share)
            smbShares.append(share)
            smbMountpoints[share.id] = mountpoint
            smbMountErrors[share.id] = nil
            try? await smbShareStore.write(smbShares)
            rebuildLocalSource()
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Remove a share: drop it from the list, unmount it (best-effort), and
    /// rebuild the local source so its titles leave the library.
    func removeSMBShare(_ share: SMBShare) async {
        smbShares.removeAll { $0.id == share.id }
        smbMountErrors[share.id] = nil
        if let mountpoint = smbMountpoints.removeValue(forKey: share.id) {
            SMBMounter.unmount(mountpoint)
        }
        try? await smbShareStore.write(smbShares)
        rebuildLocalSource()
    }

    /// Change what an SMB share holds (Movies / TV / Both) and rescan its
    /// mounted folder with the new hint.
    func setSMBShareContent(_ share: SMBShare, _ content: SMBRootContent) async {
        guard let index = smbShares.firstIndex(where: { $0.id == share.id }) else { return }
        smbShares[index].content = content
        try? await smbShareStore.write(smbShares)
        rebuildLocalSource()
    }

    /// Mount a persisted share and register its mountpoint, rebuilding the local
    /// source so its titles appear. On failure, record a status string Settings
    /// can show (e.g. NAS off-network) without dropping the saved share.
    private func mountAndRegister(_ share: SMBShare) async {
        // One attempt at a time per share — a blocking mount can run up to the
        // timeout, and network/foreground retries fire while it's in flight.
        guard !smbMountsInFlight.contains(share.id) else { return }
        smbMountsInFlight.insert(share.id)
        defer { smbMountsInFlight.remove(share.id) }
        do {
            let mountpoint = try await SMBMounter.mount(share)
            // Guard against a removal that raced the mount.
            guard smbShares.contains(where: { $0.id == share.id }) else {
                SMBMounter.unmount(mountpoint)
                return
            }
            smbMountpoints[share.id] = mountpoint
            smbMountErrors[share.id] = nil
            rebuildLocalSource()
        } catch {
            smbMountErrors[share.id] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Re-attempt every share that isn't mounted yet (skipping any already in
    /// flight). Fire-and-forget — used by the manual "Reconnect" button, the
    /// network-change monitor, and app re-activation.
    func retryUnmountedShares() {
        for share in smbShares where smbMountpoints[share.id] == nil && !smbMountsInFlight.contains(share.id) {
            Task { await mountAndRegister(share) }
        }
    }

    /// Manual "Reconnect" — same as the automatic retry.
    func remountSMBShares() { retryUnmountedShares() }

    /// Start watching for network changes so shares that were unreachable at
    /// launch (NAS asleep, away from the LAN, VPN not up) auto-mount once the
    /// path comes back — no manual Reconnect needed. Idempotent.
    private func startSMBAutoRemount() {
        guard !smbPathMonitorStarted else { return }
        smbPathMonitorStarted = true
        smbPathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.retryUnmountedShares() }
        }
        smbPathMonitor.start(queue: DispatchQueue(label: "cz.zmrhal.aether.smb.path"))
    }

    // MARK: Library + playback

    func makeLibrary() -> UnifiedLibrary {
        UnifiedLibrary(sources: connectedSources)
    }

    /// Resume store — documents-directory JSON (same-device resume + Continue
    /// Watching). No iCloud KVS: iCloud is App-Store/TestFlight-only and can't be
    /// used by the Developer-ID Mac build, so cross-device resume will come via
    /// server-side progress instead (#18).
    let resumeStore = ResumeStore(diskURL: ResumeStore.defaultDiskURL())

    /// Maps a resolved playback URL → the item it came from, so the player
    /// window (which only carries a URL) can record resume keyed by `MediaID`.
    private var playbackContext: [URL: MediaItem] = [:]

    /// Bumped whenever a resume point is written, so Discover can re-pull
    /// Continue Watching after the user closes a player window.
    private(set) var resumeRevision = 0

    /// The URL currently playing **in the main window** (inline overlay), or nil
    /// when the player is closed. Playback is presented inside the app window
    /// rather than spawning a separate window.
    var playbackURL: URL?

    /// When set, the next playback seeks here on open instead of the saved resume
    /// point — drives "Play from Beginning" (`startAt: 0`). Consumed once by
    /// `startSeconds(for:)` when the player loads.
    private var startOverride: Double?

    /// Resolve a server item and start playing it inline. `startAt` overrides the
    /// saved resume point for this playback (e.g. `0` = play from the beginning);
    /// `nil` resumes from where the user left off.
    func play(_ item: MediaItem, startAt: Double? = nil) async {
        startOverride = startAt
        // Downloaded files take absolute priority — play from disk even when
        // online, so the user always gets the fastest start and offline works.
        if let status = downloadObserver?.status(for: item.id),
           case .completed(let localURL, _) = status,
           FileManager.default.fileExists(atPath: localURL.path) {
            playbackContext[localURL] = item
            playbackURL = localURL
            return
        }
        if let url = await beginPlayback(for: item) { playbackURL = url }
    }

    /// Play a local file inline (no resume context).
    func playLocal(_ url: URL) {
        playbackContext[url] = nil
        playbackURL = url
    }

    /// Close the inline player.
    func stopPlayback() { playbackURL = nil }

    /// Shared Home/Discover rails, cached on the session. The sidebar's detail
    /// pane recreates its view on every tab switch (NavigationSplitView), so a
    /// per-view `@State` reloaded the rails on every click. Holding them here —
    /// keyed by the library + resume generation — lets a tab switch repaint
    /// instantly and only triggers a real load when something actually changed.
    private(set) var homeRailsCache: UnifiedRails = .empty
    /// True while the first rails load (empty cache) is in flight — drives the
    /// loading animation. A background revalidate over existing rails doesn't set
    /// it (content stays on screen).
    private(set) var isLoadingRails = false
    /// The `libraryToken-resumeRevision` the cache was built for; a mismatch means
    /// sources or resume state changed and the cache is stale.
    private var railsCacheKey = ""
    /// Guards against overlapping loads (Home + Discover both fire `.task` on the
    /// same generation) — a wasted concurrent fan-out, not a correctness issue.
    private var railsLoadInFlight = false

    private var currentRailsKey: String { "\(libraryToken)-\(resumeRevision)" }

    /// Load the Home/Discover rails into `homeRailsCache` if they aren't already
    /// current. A no-op (instant) when the cache matches the live generation, so
    /// switching tabs doesn't reload. `force` always re-hits the servers.
    func loadHomeRailsIfNeeded(force: Bool = false) async {
        if !force, railsCacheKey == currentRailsKey, !homeRailsCache.isEmpty { return }
        if railsLoadInFlight { return }
        railsLoadInFlight = true
        defer { railsLoadInFlight = false }
        guard hasAnySource else {
            homeRailsCache = .empty
            railsCacheKey = currentRailsKey
            return
        }
        if homeRailsCache.isEmpty { isLoadingRails = true }
        defer { isLoadingRails = false }
        let library = makeLibrary()
        let built = await library.homeRails(resumeStore: resumeStore, forceRefresh: force)
        // Don't blank existing rails on a transient empty result.
        if !built.isEmpty || homeRailsCache.isEmpty { homeRailsCache = built }
        railsCacheKey = currentRailsKey
        AetherImageCache.shared.prefetch(
            built.recentlyAdded.map(\.posterURL)
                + built.recentlyReleased.map(\.posterURL)
                + built.continueWatching.map { $0.item.backdropURL ?? $0.item.posterURL }
        )
        // Stale-while-revalidate: refresh quietly in the background if the
        // snapshot is past its window (also seeds cross-device server resume,
        // which is kept off the cold path for speed).
        guard !force, await isLibraryStale() else { return }
        let fresh = await library.homeRails(resumeStore: resumeStore, forceRefresh: true)
        if !fresh.isEmpty {
            homeRailsCache = fresh
            railsCacheKey = currentRailsKey
        }
    }

    /// Discover rails (Recently Added / Released, Top Rated, …) across sources.
    /// Served from the shared cache/snapshot instantly; pass `forceRefresh` to
    /// re-hit the servers for a background revalidate (#197 parity).
    func homeRails(forceRefresh: Bool = false) async -> UnifiedRails {
        await makeLibrary().homeRails(resumeStore: resumeStore, forceRefresh: forceRefresh)
    }

    /// Whether the persisted library snapshot is past its freshness window — used
    /// to decide whether to kick a background refresh after serving the cache.
    func isLibraryStale() async -> Bool {
        let library = makeLibrary()
        let staleMovies = await library.isStale(kind: .movie)
        let staleShows = await library.isStale(kind: .show)
        return staleMovies || staleShows
    }

    /// The item behind a player window's URL (set by `beginPlayback`).
    func item(forPlaybackURL url: URL) -> MediaItem? { playbackContext[url] }

    /// Where the player should seek on open: an explicit per-playback override
    /// (e.g. Play From Beginning = `0`), else the saved resume point. The override
    /// is consumed once so a later auto-resume isn't affected.
    func startSeconds(for item: MediaItem) async -> Double? {
        if let override = startOverride {
            startOverride = nil
            return override
        }
        return await savedResumeSeconds(for: item)
    }

    /// Saved playhead (seconds) for an item, independent of any play override —
    /// drives the Detail "Resume" affordance + Continue Watching.
    func savedResumeSeconds(for item: MediaItem) async -> Double? {
        guard let point = await resumeStore.point(for: item.id) else { return nil }
        return DetailFormatting.seconds(point.position)
    }

    /// Mark an item watched/unwatched across **every** connected source that has
    /// it (Plex `/:/scrobble`, Jellyfin `PlayedItems`), matched by shared external
    /// id — so a title on two servers stays in sync (parity with iOS).
    func markWatched(_ item: MediaItem, watched: Bool = true) async {
        await makeLibrary().markWatchedEverywhere(item, watched: watched)
        libraryToken &+= 1   // refresh watched badges
    }

    /// Source skip segments (intro / recap / credits) for the player's Skip
    /// Intro / Skip Credits + Auto-Play-Next. Empty when the source has none.
    func segments(for item: MediaItem) async -> [PlaybackSegment] {
        await source(for: item)?.segments(for: item.id) ?? []
    }

    /// The next episode after `item` in its season/show, for Auto-Play-Next.
    func nextEpisode(after item: MediaItem) async -> MediaItem? {
        await source(for: item)?.nextEpisode(after: item.id)
    }

    /// Forget an item's resume point — called when it finishes so it leaves
    /// Continue Watching and never offers "resume" a second before the end.
    func clearResume(for item: MediaItem) async {
        await resumeStore.clear(for: item.id)
        resumeRevision &+= 1
    }

    /// Remove a title from Continue Watching across **every** connected source
    /// *without* marking it watched (#368) — zero the server playhead so it
    /// drops from Plex On Deck / Jellyfin Resume and can't re-seed, then drop the
    /// local resume point and refresh the rail. The durable counterpart to
    /// `clearResume` (which is local-only) for the user-initiated "Remove".
    func removeFromContinueWatching(_ item: MediaItem) async {
        await makeLibrary().clearContinueWatchingEverywhere(item)
        await resumeStore.clear(for: item.id)
        resumeRevision &+= 1
    }

    /// Whether the item's source supports favorites (Plex/Jellyfin do; local no).
    func canFavorite(_ item: MediaItem) -> Bool {
        source(for: item)?.supportsFavorites ?? false
    }

    /// Toggle the favorite flag on the item's own source.
    func setFavorite(_ item: MediaItem, to value: Bool) async {
        guard let source = source(for: item), source.supportsFavorites else { return }
        await source.setFavorite(item.id, to: value)
        libraryToken &+= 1
    }

    /// Record a playhead position for an item. `committing` (pause/close) also
    /// pushes to iCloud KVS; the periodic tick passes `false`. Also reports the
    /// playhead to the item's server (Plex timeline / Jellyfin Sessions) so
    /// resume syncs cross-device — there's no iCloud on the Developer ID Mac
    /// build, so the server is the only cross-device path here. Best-effort.
    func recordResume(
        for item: MediaItem, seconds: Double, committing: Bool,
        durationSeconds: Double? = nil, paused: Bool = false
    ) async {
        await resumeStore.record(
            ResumePoint(mediaID: item.id, position: .seconds(seconds)),
            committing: committing
        )
        resumeRevision &+= 1
        let duration = durationSeconds.map { Duration.seconds($0) }
        await source(for: item)?.recordProgress(
            item.id, position: .seconds(seconds), duration: duration, paused: paused
        )
    }

    /// Fully hydrate a browse item — Plex/Jellyfin list items carry no track or
    /// rich metadata until fetched per-item, so the Detail screen needs this to
    /// offer Audio / Subtitle / Quality pickers. The user's playback defaults
    /// (preferred audio/subtitle language, quality) are seeded on top, matching
    /// the iOS app. Falls back to the thin item when the source can't hydrate.
    func hydratedItem(for item: MediaItem) async -> MediaItem {
        guard let source = source(for: item) else { return item }
        let full = (try? await source.item(for: item.id)) ?? item
        return playbackPrefs.applied(to: full)
    }

    /// Resolve a playable URL for an item via its source's resolver.
    func resolvedURL(for item: MediaItem) async -> URL? {
        guard let source = source(for: item) else { return nil }
        let request = PlaybackRequest(item: item, startTime: nil)
        return try? await source.resolvePlayback(request).url
    }

    /// Resolve a server item to a playback URL **and** remember the item behind
    /// that URL, so the player window can record resume / Continue Watching.
    func beginPlayback(for item: MediaItem) async -> URL? {
        guard let url = await resolvedURL(for: item) else { return nil }
        playbackContext[url] = item
        return url
    }

    /// The connected source an item belongs to.
    func source(for item: MediaItem) -> (any MediaSource)? {
        connectedSources.first { $0.id == item.id.source }
    }

    /// Set (or clear with `0`) the user's personal rating (Plex 0–10) on the
    /// item's source. Best-effort + non-throwing.
    func setRating(_ item: MediaItem, to rating: Int) async {
        guard let src = source(for: item), src.supportsUserRatings else { return }
        await src.setRating(item.id, to: rating)
    }

    /// A container's children — a show's seasons, a season's episodes — for the
    /// Detail drill-down. `[]` on failure / no source.
    func children(of item: MediaItem) async -> [MediaItem] {
        guard let source = source(for: item) else { return [] }
        return (try? await source.children(of: item.id)) ?? []
    }

    /// Resolve an episode's parent **season** and **show** (via `parentID`
    /// chaining: episode → season → show), so the episode Detail can link back up
    /// the hierarchy — e.g. opened from Continue Watching, you can still reach the
    /// season and the whole series. Either may be `nil` if not resolvable.
    func parents(of episode: MediaItem) async -> (season: MediaItem?, show: MediaItem?) {
        guard let source = source(for: episode), let seasonID = episode.parentID else { return (nil, nil) }
        let season = try? await source.item(for: seasonID)
        var show: MediaItem?
        if let showID = season?.parentID { show = try? await source.item(for: showID) }
        return (season, show)
    }

    /// The show's **On Deck** episode (parity with iOS): the in-progress episode
    /// if any, else the one after the last watched (or the first) — so the show
    /// Detail can offer "Continue Watching / Next Up". Walks seasons → episodes
    /// and intersects local resume points. `nil` when the show is fully watched
    /// or has no episodes.
    func onDeckEpisode(forShow show: MediaItem) async -> MediaItem? {
        let seasons = await children(of: show)
        var episodes: [MediaItem] = []
        for season in seasons {
            episodes.append(contentsOf: await children(of: season))
        }
        guard !episodes.isEmpty else { return nil }
        let points = await resumeStore.allPoints()
        let byID = Dictionary(points.map { ($0.mediaID, $0) }, uniquingKeysWith: { first, _ in first })
        return OnDeck.next(episodes: episodes) { episode in
            guard let point = byID[episode.id], !episode.isFullyWatched else { return nil }
            return point.updatedAt
        }
    }

    // MARK: Helpers

    /// A stable device identifier (Plex client id / Jellyfin device id),
    /// generated once and persisted in UserDefaults. Not a secret — it just has
    /// to be **stable** across launches (Plex ties the token to the client id),
    /// so UserDefaults (synchronous) is the right home; the auth *token* lives in
    /// the Keychain.
    private static func persistentID(_ key: String) -> String {
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: key)
        return new
    }
}
