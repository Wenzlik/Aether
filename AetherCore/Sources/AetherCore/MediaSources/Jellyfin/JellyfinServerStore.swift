import Foundation

/// Persists the signed-in `JellyfinServerRecord` in the Keychain — one JSON
/// blob under one key. Mirrors `PlexServerStore`.
public actor JellyfinServerStore {
    public static let keychainKey = "jellyfin.selectedServer"

    private let keychain: KeychainStore
    private let key: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(keychain: KeychainStore, key: String = keychainKey) {
        self.keychain = keychain
        self.key = key
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public func read() async throws -> JellyfinServerRecord? {
        guard let data = try await keychain.data(for: key) else { return nil }
        return try decoder.decode(JellyfinServerRecord.self, from: data)
    }

    public func write(_ record: JellyfinServerRecord) async throws {
        let data = try encoder.encode(record)
        try await keychain.setData(data, for: key)
    }

    public func clear() async throws {
        try await keychain.removeValue(for: key)
    }
}
