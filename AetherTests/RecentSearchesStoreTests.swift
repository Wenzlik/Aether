import Testing
import Foundation
@testable import AetherCore

@Suite("RecentSearchesStore")
@MainActor
struct RecentSearchesStoreTests {

    private func makeStore(maxCount: Int = 3) -> RecentSearchesStore {
        let defaults = UserDefaults(suiteName: "recent-search-test-\(UUID().uuidString)")!
        return RecentSearchesStore(defaults: defaults, maxCount: maxCount)
    }

    @Test("records newest-first, trims, dedupes case-insensitively, caps, clears")
    func behaviour() {
        let store = makeStore(maxCount: 3)

        store.record("Dune")
        store.record("  Alien  ")          // trimmed
        #expect(store.recent == ["Alien", "Dune"])

        store.record("dune")               // case-insensitive dedup → moves to front
        #expect(store.recent == ["dune", "Alien"])

        store.record("")                    // empty ignored
        store.record("   ")                 // whitespace ignored
        #expect(store.recent == ["dune", "Alien"])

        store.record("Tron")
        store.record("Akira")              // exceeds cap of 3
        #expect(store.recent == ["Akira", "Tron", "dune"])

        store.clear()
        #expect(store.recent.isEmpty)
    }

    @Test("persists across instances on the same defaults")
    func persistence() {
        let suite = "recent-search-persist-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let first = RecentSearchesStore(defaults: defaults)
        first.record("Blade Runner")
        let second = RecentSearchesStore(defaults: defaults)
        #expect(second.recent == ["Blade Runner"])
    }
}
