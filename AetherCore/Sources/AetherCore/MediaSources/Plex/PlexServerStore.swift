import Foundation

/// Persists the Plex servers Aether is connected to, in the Keychain.
///
/// Phase 2 (#325) made this a **list** — several servers from one account can be
/// enabled at once. The list lives under `listKey` as a JSON array; the legacy
/// single-record key (`keychainKey`) is migrated to a one-element list on first
/// `readAll()` and then cleared, so old installs upgrade with no re-sign-in.
///
/// The Keychain handles encryption at rest; we just hand it bytes. Errors bubble
/// up so the caller can decide whether to surface them (typically: don't — the
/// sign-in / discovery flow recovers).
public actor PlexServerStore {
    /// Legacy single-record key (pre-#325). Read for migration, then dropped.
    public static let keychainKey = "plex.selectedServer"
    /// The enabled-servers list (#325).
    public static let listKey = "plex.servers"

    private let keychain: KeychainStore
    private let key: String
    private let serverListKey: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(keychain: KeychainStore, key: String = keychainKey, listKey: String = listKey) {
        self.keychain = keychain
        self.key = key
        self.serverListKey = listKey
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    // MARK: - Single record (legacy; kept for the migration + any single-server callers)

    public func read() async throws -> PlexServerRecord? {
        guard let data = try await keychain.data(for: key) else { return nil }
        return try decoder.decode(PlexServerRecord.self, from: data)
    }

    public func write(_ record: PlexServerRecord) async throws {
        let data = try encoder.encode(record)
        try await keychain.setData(data, for: key)
    }

    // MARK: - Server list (#325)

    /// All enabled servers. Falls back to migrating a legacy single record into
    /// a one-element list when the new list key is absent.
    public func readAll() async throws -> [PlexServerRecord] {
        if let data = try await keychain.data(for: serverListKey) {
            return try decoder.decode([PlexServerRecord].self, from: data)
        }
        // Migrate a pre-#325 install: one stored record → a one-element list.
        if let legacy = try await read() { return [legacy] }
        return []
    }

    /// Replace the enabled-servers list. Also clears the legacy single key so the
    /// two representations can't diverge after an upgrade.
    public func writeAll(_ records: [PlexServerRecord]) async throws {
        let data = try encoder.encode(records)
        try await keychain.setData(data, for: serverListKey)
        try? await keychain.removeValue(for: key)
    }

    public func clear() async throws {
        try await keychain.removeValue(for: serverListKey)
        try await keychain.removeValue(for: key)
    }
}
