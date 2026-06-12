import Testing
import Foundation
@testable import AetherCore

@Suite("LibrarySort")
struct LibrarySortTests {

    @Test("Every case has a non-empty display name and a Plex parameter")
    func everyCaseIsWired() {
        for sort in LibrarySort.allCases {
            #expect(!sort.displayName.isEmpty, "missing displayName for \(sort)")
            #expect(!sort.systemImage.isEmpty, "missing systemImage for \(sort)")
            #expect(!sort.plexParameter.isEmpty, "missing plexParameter for \(sort)")
        }
    }

    @Test("Plex parameters use field:direction (or 'random'), no spaces or other separators")
    func plexParameterFormat() {
        for sort in LibrarySort.allCases where sort != .random {
            let parts = sort.plexParameter.split(separator: ":")
            #expect(parts.count == 2, "expected field:direction, got \(sort.plexParameter)")
            #expect(["asc", "desc"].contains(String(parts[1])), "bad direction in \(sort.plexParameter)")
        }
        #expect(LibrarySort.random.plexParameter == "random")
    }

    @Test("Specific mappings — guard against accidental Plex param swaps")
    func specificMappings() {
        #expect(LibrarySort.titleAZ.plexParameter == "titleSort:asc")
        #expect(LibrarySort.titleZA.plexParameter == "titleSort:desc")
        #expect(LibrarySort.yearNewest.plexParameter == "year:desc")
        #expect(LibrarySort.yearOldest.plexParameter == "year:asc")
        #expect(LibrarySort.recentlyAdded.plexParameter == "addedAt:desc")
        #expect(LibrarySort.ratingHighest.plexParameter == "audienceRating:desc")
    }

    @Test("Codable round-trip preserves the value (used by LibraryPreferencesStore)")
    func codableRoundTrip() throws {
        for sort in LibrarySort.allCases {
            let data = try JSONEncoder().encode(sort)
            let decoded = try JSONDecoder().decode(LibrarySort.self, from: data)
            #expect(decoded == sort)
        }
    }

    @Test("Default sort is `recentlyAdded` — surfaces new arrivals when the user hasn't picked")
    func defaultIsRecentlyAdded() {
        #expect(LibrarySort.default == .recentlyAdded)
    }
}

@Suite("MediaSourceID.stableKey")
struct MediaSourceIDStableKeyTests {

    @Test("mock → 'mock'")
    func mock() {
        #expect(MediaSourceID.mock.stableKey == "mock")
    }

    @Test("plex(serverID:) embeds the server identifier")
    func plex() {
        #expect(MediaSourceID.plex(serverID: "abc-123").stableKey == "plex.abc-123")
    }

    @Test("smb(id:) / dlna(udn:) embed their stable key")
    func networkShares() {
        #expect(MediaSourceID.smb(id: "ABC-123").stableKey == "smb.ABC-123")
        #expect(MediaSourceID.dlna(udn: "uuid:9f").stableKey == "dlna.uuid:9f")
    }

    @Test("stableKey is deterministic across calls (no nondeterminism)")
    func deterministic() {
        let key1 = MediaSourceID.plex(serverID: "X").stableKey
        let key2 = MediaSourceID.plex(serverID: "X").stableKey
        #expect(key1 == key2)
    }
}

// MARK: - LibrarySort.sorted(_:) (#294)

private struct SortableStub: LibrarySortable {
    let title: String
    let year: Int?
    let dateAdded: Date?
    let communityRating: Double?
    init(_ title: String, year: Int? = nil, dateAdded: Date? = nil, rating: Double? = nil) {
        self.title = title; self.year = year; self.dateAdded = dateAdded; self.communityRating = rating
    }
}

@Suite("LibrarySort.sorted")
struct LibrarySortSortedTests {
    @Test("ratingHighest — highest first, unrated always last (not interleaved)")
    func ratingHighest() {
        let items = [
            SortableStub("A", rating: nil),
            SortableStub("B", rating: 7.5),
            SortableStub("C", rating: 9.1),
            SortableStub("D", rating: nil),
        ]
        let sorted = LibrarySort.ratingHighest.sorted(items)
        // Ratings descending with nils sunk to the end (relative nil order is
        // unstable, so assert the rating sequence, not titles).
        #expect(sorted.map(\.communityRating) == [9.1, 7.5, nil, nil])
        #expect(sorted.first?.title == "C")
    }

    @Test("titleAZ / titleZA — case-insensitive")
    func title() {
        let items = [SortableStub("Banana"), SortableStub("apple"), SortableStub("Cherry")]
        #expect(LibrarySort.titleAZ.sorted(items).map(\.title) == ["apple", "Banana", "Cherry"])
        #expect(LibrarySort.titleZA.sorted(items).map(\.title) == ["Cherry", "Banana", "apple"])
    }

    @Test("yearNewest — yearless titles sort last")
    func yearNewest() {
        let items = [SortableStub("X", year: 2000), SortableStub("Y", year: nil), SortableStub("Z", year: 2020)]
        #expect(LibrarySort.yearNewest.sorted(items).map(\.title) == ["Z", "X", "Y"])
    }
}
