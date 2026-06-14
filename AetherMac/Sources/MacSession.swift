import SwiftUI
import AetherCore

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
    let plexAuthClient: PlexAuthClient
    let jellyfinAuthClient: JellyfinAuthClient
    private let plexResourceClient: PlexResourceClient
    private let plexServerStore: PlexServerStore
    private let jellyfinServerStore: JellyfinServerStore

    private(set) var plexSources: [PlexMediaSource] = []
    private(set) var jellyfinSource: JellyfinMediaSource?

    /// Server display names, mirrored as plain strings for the Settings UI —
    /// the source objects are actors, so their `displayName` can't be read from
    /// the main actor synchronously.
    private(set) var plexServerNames: [String] = []
    private(set) var jellyfinServerName: String?

    /// App-wide display + playback defaults, shared with the iOS app's model.
    /// On Mac we wire the ones that affect what's on screen: the watched-poster
    /// treatment (`\.watchedDisplay`) and hide-watched-in-discovery.
    let playbackPrefs = PlaybackPreferencesStore()

    var isPlexConnected: Bool { !plexSources.isEmpty }
    var isJellyfinConnected: Bool { jellyfinSource != nil }
    var hasAnySource: Bool { isPlexConnected || isJellyfinConnected }

    /// Every connected source — what `UnifiedLibrary` fans out over.
    var connectedSources: [any MediaSource] {
        var list: [any MediaSource] = []
        list.append(contentsOf: plexSources)
        if let jellyfinSource { list.append(jellyfinSource) }
        return list
    }

    private static let plexTokenKey = "plex.authToken"
    private static let plexClientIDKey = "plex.clientIdentifier"
    private static let jellyfinDeviceIDKey = "jellyfin.deviceID"

    init() {
        let clientID = Self.persistentID(Self.plexClientIDKey)
        let deviceID = Self.persistentID(Self.jellyfinDeviceIDKey)
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
        plexAuthClient = PlexAuthClient(api: api, configuration: plexConfiguration)
        jellyfinAuthClient = JellyfinAuthClient(api: api, configuration: jellyfinConfiguration)
        plexResourceClient = PlexResourceClient(api: api, configuration: plexConfiguration)
        plexServerStore = PlexServerStore(keychain: keychain)
        jellyfinServerStore = JellyfinServerStore(keychain: keychain)
    }

    // MARK: Restore

    private var didRestore = false

    func restore() async {
        // Guard against re-running when the library view reappears after the
        // player closes (the player replaces it, so `.task` would fire again).
        guard !didRestore else { return }
        didRestore = true
        await resumeStore.loadFromDisk()
        if let records = try? await plexServerStore.readAll(), !records.isEmpty {
            plexSources = records.map(makePlexSource)
            plexServerNames = records.map(\.name)
        }
        if let record = try? await jellyfinServerStore.read(), let source = makeJellyfinSource(record) {
            jellyfinSource = source
            jellyfinServerName = record.serverName
        }
    }

    // MARK: Plex

    /// Called with the token from `PlexSignInViewModel`'s `.success`. Persists it,
    /// discovers reachable servers, and builds the live sources.
    func completePlexSignIn(token: String) async {
        try? await keychain.setString(token, for: Self.plexTokenKey)
        guard let resources = try? await plexResourceClient.resources(token: token) else { return }
        let records = PlexServerSelector().rankedSelections(from: resources).map { $0.makeRecord() }
        guard !records.isEmpty else { return }
        try? await plexServerStore.writeAll(records)
        plexSources = records.map(makePlexSource)
        plexServerNames = records.map(\.name)
    }

    func signOutPlex() async {
        try? await keychain.removeValue(for: Self.plexTokenKey)
        try? await plexServerStore.clear()
        plexSources = []
        plexServerNames = []
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

    func completeJellyfinSignIn(_ record: JellyfinServerRecord) async {
        try? await jellyfinServerStore.write(record)
        jellyfinSource = makeJellyfinSource(record)
        jellyfinServerName = record.serverName
    }

    func signOutJellyfin() async {
        try? await jellyfinServerStore.clear()
        jellyfinSource = nil
        jellyfinServerName = nil
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

    // MARK: Library + playback

    func makeLibrary() -> UnifiedLibrary {
        UnifiedLibrary(sources: connectedSources)
    }

    /// Disk-backed resume store (Documents) — the Mac player records playhead
    /// positions here and `homeRails` reads them back as Continue Watching.
    let resumeStore = ResumeStore()

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

    /// Resolve a server item and start playing it inline.
    func play(_ item: MediaItem) async {
        if let url = await beginPlayback(for: item) { playbackURL = url }
    }

    /// Play a local file inline (no resume context).
    func playLocal(_ url: URL) {
        playbackContext[url] = nil
        playbackURL = url
    }

    /// Close the inline player.
    func stopPlayback() { playbackURL = nil }

    /// Discover rails (Recently Added / Released, Top Rated, …) across sources.
    func homeRails() async -> UnifiedRails {
        await makeLibrary().homeRails(resumeStore: resumeStore)
    }

    /// The item behind a player window's URL (set by `beginPlayback`).
    func item(forPlaybackURL url: URL) -> MediaItem? { playbackContext[url] }

    /// Saved playhead (seconds) for an item, for resume-on-open.
    func resumeSeconds(for item: MediaItem) async -> Double? {
        guard let point = await resumeStore.point(for: item.id) else { return nil }
        return DetailFormatting.seconds(point.position)
    }

    /// Record a playhead position for an item. `committing` (pause/close) also
    /// pushes to iCloud KVS; the periodic tick passes `false`.
    func recordResume(for item: MediaItem, seconds: Double, committing: Bool) async {
        await resumeStore.record(
            ResumePoint(mediaID: item.id, position: .seconds(seconds)),
            committing: committing
        )
        resumeRevision &+= 1
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

    /// A container's children — a show's seasons, a season's episodes — for the
    /// Detail drill-down. `[]` on failure / no source.
    func children(of item: MediaItem) async -> [MediaItem] {
        guard let source = source(for: item) else { return [] }
        return (try? await source.children(of: item.id)) ?? []
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
