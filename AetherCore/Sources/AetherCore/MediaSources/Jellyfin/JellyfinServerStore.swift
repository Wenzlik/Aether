import Foundation

/// Persists the signed-in Jellyfin servers in the Keychain. Mirrors
/// `PlexServerStore`: the list lives under `listKey` as a JSON array; the legacy
/// single-record key (`keychainKey`) is migrated to a one-element list on first
/// `readAll()` and then cleared, so existing installs upgrade with no re-sign-in.
public actor JellyfinServerStore {
    /// Legacy single-record key (pre-multi-server). Read for migration, then dropped.
    public static let keychainKey = "jellyfin.selectedServer"
    /// The connected-servers list.
    public static let listKey = "jellyfin.servers"

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

    // MARK: - Single record (legacy; kept for migration)

    public func read() async throws -> JellyfinServerRecord? {
        guard let data = try await keychain.data(for: key) else { return nil }
        return try decoder.decode(JellyfinServerRecord.self, from: data)
    }

    public func write(_ record: JellyfinServerRecord) async throws {
        let data = try encoder.encode(record)
        try await keychain.setData(data, for: key)
    }

    // MARK: - Server list

    /// All connected servers. Migrates a legacy single record into a one-element
    /// list when the new list key is absent.
    public func readAll() async throws -> [JellyfinServerRecord] {
        if let data = try await keychain.data(for: serverListKey) {
            return try decoder.decode([JellyfinServerRecord].self, from: data)
        }
        if let legacy = try await read() { return [legacy] }
        return []
    }

    /// Replace the connected-servers list, clearing the legacy single key so the
    /// two representations can't diverge after an upgrade.
    public func writeAll(_ records: [JellyfinServerRecord]) async throws {
        let data = try encoder.encode(records)
        try await keychain.setData(data, for: serverListKey)
        try? await keychain.removeValue(for: key)
    }

    public func clear() async throws {
        try await keychain.removeValue(for: serverListKey)
        try await keychain.removeValue(for: key)
    }
}
