import Foundation

/// Keychain-backed persistence for the connected Emby servers. Mirrors
/// `PlexServerStore` / `JellyfinServerStore`: the list lives under `listKey`; a
/// legacy single record under `keychainKey` is migrated to a one-element list on
/// first `readAll()` and then cleared, so existing installs upgrade seamlessly.
public actor EmbyServerStore {
    /// Legacy single-record key (pre-multi-server). Read for migration, then dropped.
    public static let keychainKey = "emby.selectedServer"
    /// The connected-servers list.
    public static let listKey = "emby.servers"

    private let keychain: KeychainStore
    private let key: String
    private let serverListKey: String

    public init(keychain: KeychainStore, key: String = keychainKey, listKey: String = listKey) {
        self.keychain = keychain
        self.key = key
        self.serverListKey = listKey
    }

    // MARK: - Single record (legacy; kept for migration)

    public func read() async throws -> EmbyServerRecord? {
        guard let data = try await keychain.data(for: key) else { return nil }
        return try JSONDecoder().decode(EmbyServerRecord.self, from: data)
    }

    public func write(_ record: EmbyServerRecord) async throws {
        let data = try JSONEncoder().encode(record)
        try await keychain.setData(data, for: key)
    }

    // MARK: - Server list

    /// All connected servers. Migrates a legacy single record into a one-element
    /// list when the new list key is absent.
    public func readAll() async throws -> [EmbyServerRecord] {
        if let data = try await keychain.data(for: serverListKey) {
            return try JSONDecoder().decode([EmbyServerRecord].self, from: data)
        }
        if let legacy = try await read() { return [legacy] }
        return []
    }

    /// Replace the connected-servers list, clearing the legacy single key so the
    /// two representations can't diverge after an upgrade.
    public func writeAll(_ records: [EmbyServerRecord]) async throws {
        let data = try JSONEncoder().encode(records)
        try await keychain.setData(data, for: serverListKey)
        try? await keychain.removeValue(for: key)
    }

    public func clear() async throws {
        try await keychain.removeValue(for: serverListKey)
        try await keychain.removeValue(for: key)
    }
}
