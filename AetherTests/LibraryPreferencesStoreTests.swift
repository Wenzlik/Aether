import Testing
import Foundation
@testable import AetherCore

@Suite("LibraryPreferencesStore")
struct LibraryPreferencesStoreTests {

    private func makeStore(suffix: String = UUID().uuidString) -> LibraryPreferencesStore {
        let keychain = KeychainStore(
            service: "cz.zmrhal.aether.tests.\(suffix)",
            backing: .memory
        )
        return LibraryPreferencesStore(keychain: keychain)
    }

    private let sampleLibraryID = Library.ID(
        source: .plex(serverID: "server-uuid"),
        rawValue: "1"
    )

    @Test("sort returns nil for an untouched library")
    func nilWhenUnset() async {
        let store = makeStore()
        let read = await store.sort(for: sampleLibraryID)
        #expect(read == nil)
    }

    @Test("setSort → sort round-trips the value")
    func roundTrip() async {
        let store = makeStore()
        await store.setSort(.yearNewest, for: sampleLibraryID)
        let read = await store.sort(for: sampleLibraryID)
        #expect(read == .yearNewest)
    }

    @Test("Each LibrarySort case can be persisted and read back")
    func everyCaseRoundTrips() async {
        for sort in LibrarySort.allCases {
            let store = makeStore()
            await store.setSort(sort, for: sampleLibraryID)
            let read = await store.sort(for: sampleLibraryID)
            #expect(read == sort, "round-trip failed for \(sort)")
        }
    }

    @Test("setSort overwrites a previous value (not appended)")
    func setSortOverwrites() async {
        let store = makeStore()
        await store.setSort(.titleAZ, for: sampleLibraryID)
        await store.setSort(.ratingHighest, for: sampleLibraryID)
        let read = await store.sort(for: sampleLibraryID)
        #expect(read == .ratingHighest)
    }

    @Test("clearSort removes the persisted value")
    func clearSort() async {
        let store = makeStore()
        await store.setSort(.random, for: sampleLibraryID)
        await store.clearSort(for: sampleLibraryID)
        let read = await store.sort(for: sampleLibraryID)
        #expect(read == nil)
    }

    @Test("Per-library isolation — two libraries on the same source don't collide")
    func perLibraryIsolation() async {
        let store = makeStore()
        let movies = Library.ID(source: .plex(serverID: "s"), rawValue: "1")
        let shows  = Library.ID(source: .plex(serverID: "s"), rawValue: "2")

        await store.setSort(.titleAZ, for: movies)
        await store.setSort(.yearNewest, for: shows)

        #expect(await store.sort(for: movies) == .titleAZ)
        #expect(await store.sort(for: shows) == .yearNewest)
    }

    @Test("Per-source isolation — same library raw value on different servers stays separate")
    func perSourceIsolation() async {
        let store = makeStore()
        let mine   = Library.ID(source: .plex(serverID: "mine"),   rawValue: "1")
        let friend = Library.ID(source: .plex(serverID: "friend"), rawValue: "1")

        await store.setSort(.titleAZ, for: mine)
        await store.setSort(.ratingHighest, for: friend)

        #expect(await store.sort(for: mine) == .titleAZ)
        #expect(await store.sort(for: friend) == .ratingHighest)
    }
}
