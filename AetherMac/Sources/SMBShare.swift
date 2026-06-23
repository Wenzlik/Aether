import Foundation
import AetherCore

/// A configured SMB share the user added on macOS.
///
/// Unlike iOS — which has no system SMB mounting and so speaks SMB in-process
/// via the `SMBClient` package plus a localhost range-proxy (see
/// `Aether/Sources/SMB/`) — the Mac mounts the share through the **kernel SMB
/// client** (NetFS → smbfs) at `/Volumes/<share>` and then scans it like any
/// other local folder. mpv plays the mounted file path directly (the Homebrew
/// libmpv/FFmpeg has no `smb://` protocol, so a real filesystem path is
/// required). So all this type needs to persist is what's required to
/// (re)mount the share on launch.
struct SMBShare: Codable, Identifiable, Hashable, Sendable {
    /// Stable identity, so Settings rows and the runtime mountpoint map survive
    /// edits and reorderings.
    let id: UUID
    /// Host or IP of the SMB server, e.g. `nas.local` or `192.168.1.10`.
    var host: String
    /// The share (volume) name exported by the server, e.g. `Media`.
    var shareName: String
    /// Optional credentials. An empty/`nil` username mounts as guest.
    var username: String?
    var password: String?

    init(id: UUID = UUID(), host: String, shareName: String, username: String?, password: String?) {
        self.id = id
        self.host = host
        self.shareName = shareName
        self.username = username
        self.password = password
    }

    /// What the Settings row shows — e.g. "Media on nas.local".
    var displayName: String { "\(shareName) on \(host)" }

    /// `smb://host/share`, percent-encoded — the URL handed to NetFS to mount.
    /// Credentials are NOT embedded here; they're passed to NetFS separately so
    /// they never leak into logs or the returned mountpoint.
    var mountURL: URL? {
        var components = URLComponents()
        components.scheme = "smb"
        components.host = host.trimmingCharacters(in: .whitespaces)
        // `path` must be absolute; the share is the first path segment.
        let share = shareName.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        components.path = "/" + share
        return components.url
    }
}

/// Keychain-backed persistence for the user's SMB shares (including passwords) —
/// one JSON array under one key. Mirrors `JellyfinServerStore`, but holds an
/// array since a Mac can mount several NAS volumes at once.
actor SMBShareStore {
    static let keychainKey = "smb.shares"

    private let keychain: KeychainStore
    private let key: String

    init(keychain: KeychainStore, key: String = keychainKey) {
        self.keychain = keychain
        self.key = key
    }

    /// All persisted shares, `[]` when none have been added.
    func read() async throws -> [SMBShare] {
        guard let data = try await keychain.data(for: key) else { return [] }
        return try JSONDecoder().decode([SMBShare].self, from: data)
    }

    func write(_ shares: [SMBShare]) async throws {
        let data = try JSONEncoder().encode(shares)
        try await keychain.setData(data, for: key)
    }

    func clear() async throws {
        try await keychain.removeValue(for: key)
    }
}
