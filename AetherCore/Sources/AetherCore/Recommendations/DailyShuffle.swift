import Foundation

/// A small, fully deterministic RNG (SplitMix64) so a shuffle can be reproduced
/// from a seed. Used by `DailyShuffle` to keep "Picked for You" stable within a
/// day instead of re-rolling on every view render.
public struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) { self.state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Day-stable shuffling for discovery rails.
///
/// `Array.shuffled()` re-rolls every call, so using it in a SwiftUI computed
/// property (or on every foreground `load()`) makes a rail visibly churn. Seeding
/// the shuffle with the **calendar day** instead gives a single, stable order for
/// the whole day that quietly rotates once at midnight — "fresh picks daily"
/// without the flicker.
public enum DailyShuffle {
    /// The per-day seed: whole days since the reference date. Same calendar day ⇒
    /// same seed ⇒ same order (for the same input).
    public static func daySeed(_ date: Date = Date()) -> UInt64 {
        UInt64(max(0, Int(date.timeIntervalSinceReferenceDate / 86_400)))
    }

    /// `items` shuffled deterministically for the given day. Stable across renders
    /// and relaunches within the same day; a different order the next day.
    public static func shuffled<T>(_ items: [T], date: Date = Date()) -> [T] {
        var rng = SeededGenerator(seed: daySeed(date))
        return items.shuffled(using: &rng)
    }
}
