import Foundation

/// A lightweight model of the user's taste, learned from their own library's
/// watch-state. Powers the Discover "Recommended by Aether" hero — no query, no
/// network, deterministic, works on every platform (including tvOS).
///
/// The signal is genre preference: titles the user has finished, favourited, or
/// rated highly contribute their genres at increasing weights. Scoring an
/// unwatched candidate is then just the overlap of its genres with those
/// weights.
public struct TasteProfile: Sendable, Equatable {
    /// Genre name → preference weight (higher = stronger). Empty when there's
    /// nothing to learn from yet (a fresh library).
    public let genreWeights: [String: Double]

    public init(genreWeights: [String: Double]) {
        self.genreWeights = genreWeights
    }

    /// `true` when no taste signal exists yet — callers fall back to a generic
    /// pick so the hero is never empty.
    public var isEmpty: Bool { genreWeights.isEmpty }

    /// Build a profile from the library's watch-state. Each title contributes
    /// its genres at a weight derived from the clearest "more of this" signals
    /// we have: a fully-watched title counts as 1; a favourited title or one the
    /// user rated highly (≥ 8/10 personal rating) adds a stronger boost.
    public static func from(library items: [UnifiedMediaItem]) -> TasteProfile {
        var weights: [String: Double] = [:]
        for item in items {
            var weight = 0.0
            if item.isFullyWatched { weight += 1 }
            if item.sources.contains(where: { $0.item.isFavorite }) { weight += 2 }
            let topRating = item.sources.compactMap { $0.item.userRating }.max() ?? 0
            if topRating >= 8 { weight += 2 }
            guard weight > 0 else { continue }
            for genre in item.genres { weights[genre, default: 0] += weight }
        }
        return TasteProfile(genreWeights: weights)
    }

    /// How well a title's genres overlap this profile.
    func score(_ item: UnifiedMediaItem) -> Double {
        item.genres.reduce(0) { $0 + (genreWeights[$1] ?? 0) }
    }
}

public extension RecommendationEngine {
    /// Unprompted, taste-based recommendations for the Discover hero. Ranks
    /// **unwatched** titles by `profile` genre overlap, then by rating, then by
    /// recency. When the profile is empty (nothing learned yet) it falls back to
    /// the best-rated unwatched titles, so the hero is never empty.
    ///
    /// Pass the *full* library to learn taste from (it reads watched titles), but
    /// the returned picks are always unwatched — Discover surfaces what's ahead.
    func recommended(
        from items: [UnifiedMediaItem],
        profile: TasteProfile,
        limit: Int
    ) -> [UnifiedMediaItem] {
        func rating(_ item: UnifiedMediaItem) -> Double {
            item.tmdbRating ?? item.communityRating ?? 0
        }
        let candidates = items.filter { !$0.isFullyWatched }

        func bestRated() -> [UnifiedMediaItem] {
            Array(candidates.sorted { rating($0) > rating($1) }.prefix(limit))
        }

        guard !profile.isEmpty else { return bestRated() }

        let scored = candidates
            .map { (item: $0, score: profile.score($0)) }
            .filter { $0.score > 0 }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                if rating($0.item) != rating($1.item) { return rating($0.item) > rating($1.item) }
                return ($0.item.year ?? 0) > ($1.item.year ?? 0)
            }
            .prefix(limit)
            .map(\.item)

        // The profile matched no genres in the catalogue — fall back to the
        // best-rated unwatched titles so callers always get picks.
        return scored.isEmpty ? bestRated() : scored
    }
}
