import Foundation

/// Keychain-backed persistence for a single `EmbyServerRecord`. The actor
/// guarantees exclusive access when reading/writing across concurrent callers.
public actor EmbyServerStore {
    private let keychain: KeychainStore
    private static let key = "emby.selectedServer"

    public init(keychain: KeychainStore) {
        self.keychain = keychain
    }

    public func read() async throws -> EmbyServerRecord? {
        guard let data = try await keychain.data(for: Self.key) else { return nil }
        return try JSONDecoder().decode(EmbyServerRecord.self, from: data)
    }

    public func write(_ record: EmbyServerRecord) async throws {
        let data = try JSONEncoder().encode(record)
        try await keychain.setData(data, for: Self.key)
    }

    public func clear() async throws {
        try await keychain.removeValue(for: Self.key)
    }
}
