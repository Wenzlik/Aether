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

    func restore() async {
        if let records = try? await plexServerStore.readAll(), !records.isEmpty {
            plexSources = records.map(makePlexSource)
        }
        if let record = try? await jellyfinServerStore.read(), let source = makeJellyfinSource(record) {
            jellyfinSource = source
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
    }

    func signOutPlex() async {
        try? await keychain.removeValue(for: Self.plexTokenKey)
        try? await plexServerStore.clear()
        plexSources = []
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
    }

    func signOutJellyfin() async {
        try? await jellyfinServerStore.clear()
        jellyfinSource = nil
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

    /// In-memory resume store — enough for `homeRails` (no on-device resume
    /// tracking on Mac yet, so Continue Watching stays empty for now).
    let resumeStore = ResumeStore()

    /// Discover rails (Recently Added / Released, Top Rated, …) across sources.
    func homeRails() async -> UnifiedRails {
        await makeLibrary().homeRails(resumeStore: resumeStore)
    }

    /// Resolve a playable URL for an item via its source's resolver.
    func resolvedURL(for item: MediaItem) async -> URL? {
        guard let source = source(for: item) else { return nil }
        let request = PlaybackRequest(item: item, startTime: nil)
        return try? await source.resolvePlayback(request).url
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
