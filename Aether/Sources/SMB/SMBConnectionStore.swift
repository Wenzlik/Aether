import Foundation
import AetherCore

/// Persists the configured `SMBConnection` (incl. credentials) in the Keychain —
/// one JSON blob under one key. Mirrors `JellyfinServerStore`. v1 holds a single
/// connection; the key could become a list later (#214).
actor SMBConnectionStore {
    static let keychainKey = "smb.connection"

    private let keychain: KeychainStore
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(keychain: KeychainStore, key: String = keychainKey) {
        self.keychain = keychain
        self.key = key
    }

    func read() async throws -> SMBConnection? {
        guard let data = try await keychain.data(for: key) else { return nil }
        return try decoder.decode(SMBConnection.self, from: data)
    }

    func write(_ connection: SMBConnection) async throws {
        try await keychain.setData(try encoder.encode(connection), for: key)
    }

    func clear() async throws {
        try await keychain.removeValue(for: key)
    }
}
