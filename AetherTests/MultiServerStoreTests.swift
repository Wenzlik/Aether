import Testing
import Foundation
@testable import AetherCore

@Suite("Jellyfin/Emby server stores — multi-server list")
struct MultiServerStoreTests {

    private func makeKeychain() -> KeychainStore {
        KeychainStore(service: "cz.zmrhal.aether.tests.\(UUID().uuidString)", backing: .memory)
    }

    private func jf(_ id: String) -> JellyfinServerRecord {
        JellyfinServerRecord(baseURLString: id, accessToken: "tok-\(id)", userID: "u-\(id)", serverName: "JF \(id)")
    }
    private func em(_ id: String) -> EmbyServerRecord {
        EmbyServerRecord(baseURLString: id, accessToken: "tok-\(id)", userID: "u-\(id)", serverName: "Emby \(id)")
    }

    // MARK: - Jellyfin

    @Test("Jellyfin: writeAll → readAll round-trips the list")
    func jellyfinListRoundTrip() async throws {
        let store = JellyfinServerStore(keychain: makeKeychain())
        let records = [jf("a"), jf("b")]
        try await store.writeAll(records)
        #expect(try await store.readAll() == records)
    }

    @Test("Jellyfin: a legacy single record migrates into a one-element list")
    func jellyfinLegacyMigration() async throws {
        let store = JellyfinServerStore(keychain: makeKeychain())
        try await store.write(jf("legacy"))          // pre-multi-server single record
        let all = try await store.readAll()          // first list read migrates it
        #expect(all == [jf("legacy")])
        // After a writeAll the legacy single key is cleared.
        try await store.writeAll([jf("a"), jf("b")])
        #expect(try await store.read() == nil)
        #expect(try await store.readAll() == [jf("a"), jf("b")])
    }

    @Test("Jellyfin: readAll is empty by default; clear empties it")
    func jellyfinEmptyAndClear() async throws {
        let store = JellyfinServerStore(keychain: makeKeychain())
        #expect(try await store.readAll().isEmpty)
        try await store.writeAll([jf("a")])
        try await store.clear()
        #expect(try await store.readAll().isEmpty)
    }

    // MARK: - Emby

    @Test("Emby: writeAll → readAll round-trips the list")
    func embyListRoundTrip() async throws {
        let store = EmbyServerStore(keychain: makeKeychain())
        let records = [em("a"), em("b")]
        try await store.writeAll(records)
        #expect(try await store.readAll() == records)
    }

    @Test("Emby: a legacy single record migrates into a one-element list")
    func embyLegacyMigration() async throws {
        let store = EmbyServerStore(keychain: makeKeychain())
        try await store.write(em("legacy"))
        #expect(try await store.readAll() == [em("legacy")])
    }
}
