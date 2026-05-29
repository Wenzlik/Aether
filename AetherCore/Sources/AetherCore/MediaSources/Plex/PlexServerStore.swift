import Foundation

/// Persists the user's currently-selected `PlexServerRecord` in the Keychain.
///
/// Tiny by design — one JSON blob under one key. The Keychain handles the
/// encryption at rest; we just hand it bytes. Errors bubble up so the caller
/// can decide whether to surface them in UI (typically: don't, just sign-in
/// flow recovers).
public actor PlexServerStore {
    public static let keychainKey = "plex.selectedServer"

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

    public func read() async throws -> PlexServerRecord? {
        guard let data = try await keychain.data(for: key) else { return nil }
        return try decoder.decode(PlexServerRecord.self, from: data)
    }

    public func write(_ record: PlexServerRecord) async throws {
        let data = try encoder.encode(record)
        try await keychain.setData(data, for: key)
    }

    public func clear() async throws {
        try await keychain.removeValue(for: key)
    }
}
