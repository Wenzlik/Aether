import Testing
import Foundation
@testable import AetherCore

@Suite("DailyShuffle — day-stable discovery ordering")
struct DailyShuffleTests {
    private let items = Array(1...30)
    /// A timestamp pinned to the start of a day block (whole multiple of 86_400),
    /// so "same day, different time" stays inside one block.
    private let dayStart = Date(timeIntervalSinceReferenceDate: 8101 * 86_400)

    @Test("Same day → identical order, regardless of time of day")
    func stableWithinDay() {
        let morning = dayStart.addingTimeInterval(3_600)
        let evening = dayStart.addingTimeInterval(80_000)
        #expect(DailyShuffle.shuffled(items, date: morning) == DailyShuffle.shuffled(items, date: evening))
    }

    @Test("The shuffle is a true permutation — same elements, reordered")
    func permutation() {
        #expect(DailyShuffle.shuffled(items, date: dayStart).sorted() == items)
    }

    @Test("A new day re-rolls the seed and the order")
    func rotatesDaily() {
        let nextDay = dayStart.addingTimeInterval(86_400)
        #expect(DailyShuffle.daySeed(dayStart) != DailyShuffle.daySeed(nextDay))
        // With 30 distinct items the odds of two seeds landing on the same
        // permutation are ~1/30!, so differing orders is a safe assertion.
        #expect(DailyShuffle.shuffled(items, date: dayStart) != DailyShuffle.shuffled(items, date: nextDay))
    }

    @Test("An empty input shuffles to empty (no crash)")
    func emptyInput() {
        #expect(DailyShuffle.shuffled([Int](), date: dayStart).isEmpty)
    }
}
