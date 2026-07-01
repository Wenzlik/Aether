import Foundation

/// A deterministic recommendation request — the filter the engine applies over
/// the unified library.
///
/// This is the *deterministic* surface (genres, runtime, type, watched). The
/// natural-language nuance of a query ("not too gory", "like The Shining") is
/// resolved one layer up by the Foundation Models concierge, which turns free
/// text into these fields and then re-ranks the shortlist this engine returns.
/// See `docs/next-steps/0.9-apple-intelligence.md`.
public struct RecommendationRequest: Sendable, Equatable {
    /// Catalogue genres to match (case-insensitive). Empty = any genre.
    public var genres: [String]
    /// Only titles of this kind (`.movie` / `.show`). `nil` = any.
    public var type: MediaItem.Kind?
    /// Drop titles longer than this. Titles with unknown runtime are kept (we
    /// don't disqualify on missing data) but rank below known-good matches.
    public var maxRuntime: Duration?
    /// Drop titles the user has already fully watched.
    public var excludeWatched: Bool
    /// Maximum shortlist size handed to the caller (and, in P2, to the model).
    public var limit: Int

    public init(
        genres: [String] = [],
        type: MediaItem.Kind? = nil,
        maxRuntime: Duration? = nil,
        excludeWatched: Bool = true,
        limit: Int = 15
    ) {
        self.genres = genres
        self.type = type
        self.maxRuntime = maxRuntime
        self.excludeWatched = excludeWatched
        self.limit = limit
    }
}

/// Deterministic, library-grounded recommendation core.
///
/// Pure and synchronous: it takes a snapshot of `UnifiedMediaItem`s (the caller
/// fetches them from `UnifiedLibrary.unifiedItems(kind:)`) and returns a ranked
/// shortlist. No LLM, no I/O, no UIKit — so it runs on **every** platform
/// including tvOS, and is fully unit-testable.
///
/// The shortlist it returns is the candidate set the AI layer is allowed to pick
/// from (the model never sees the whole catalogue and can only recommend titles
/// the user actually owns).
public struct RecommendationEngine: Sendable {
    public init() {}

    /// Filter `items` by the request, then rank by relevance.
    ///
    /// Ranking order (all deterministic, locale-independent):
    /// 1. number of requested genres matched (more = better)
    /// 2. taste overlap — how well the title's genres match what the user tends
    ///    to like (`taste`); `0` for everyone when no profile is supplied, so
    ///    this tier is then a no-op and ranking falls straight through to rating
    /// 3. best available rating (`tmdbRating` ?? `communityRating`)
    /// 4. known runtime within `maxRuntime` ranks above unknown runtime
    /// 5. newer release year
    /// 6. title (stable tie-break)
    ///
    /// Taste sits *below* the explicit genre-match count: a request's stated
    /// intent always wins, and taste only re-orders titles that satisfy the ask
    /// equally well (or, for a genre-less "recommend me something", becomes the
    /// primary signal).
    /// - Parameter taste: the user's learned genre preferences. `nil` keeps the
    ///   ranking purely request-driven (the original behaviour), so callers that
    ///   don't personalise are unaffected.
    public func recommend(
        from items: [UnifiedMediaItem],
        request: RecommendationRequest,
        taste: TasteProfile? = nil
    ) -> [UnifiedMediaItem] {
        guard request.limit > 0 else { return [] }

        let requestedGenres = Set(request.genres.map(Self.normalize)).subtracting([""])

        let candidates: [Candidate] = items.compactMap { item in
            // Type filter.
            if let type = request.type, item.type != type { return nil }

            // Genre filter — must match at least one requested genre (if any).
            let matched = requestedGenres.isEmpty
                ? 0
                : requestedGenres.intersection(item.genres.map(Self.normalize)).count
            if !requestedGenres.isEmpty && matched == 0 { return nil }

            // Runtime filter — exclude only titles whose *known* runtime exceeds
            // the cap. Unknown runtime is kept but flagged so it ranks lower.
            let runtimeFits: Bool
            if let maxRuntime = request.maxRuntime, let runtime = item.runtime {
                if runtime > maxRuntime { return nil }
                runtimeFits = true
            } else {
                runtimeFits = request.maxRuntime == nil
            }

            // Watched filter.
            if request.excludeWatched && item.isFullyWatched { return nil }

            return Candidate(
                item: item,
                matchedGenres: matched,
                tasteScore: taste?.score(item) ?? 0,
                runtimeKnownFit: runtimeFits
            )
        }

        let ranked = candidates.sorted(by: Self.ranksHigher)
        return Array(ranked.prefix(request.limit)).map(\.item)
    }

    /// The genres present in `items`, deduplicated case-insensitively and sorted.
    /// Useful for the App Intent's genre parameter and the keyword fallback parser.
    public func availableGenres(in items: [UnifiedMediaItem]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for genre in items.flatMap(\.genres) {
            let key = Self.normalize(genre)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(genre)
        }
        return result.sorted { $0.lowercased() < $1.lowercased() }
    }

    // MARK: - Ranking

    private struct Candidate {
        let item: UnifiedMediaItem
        let matchedGenres: Int
        /// Genre overlap with the user's taste profile; 0 when not personalising.
        let tasteScore: Double
        let runtimeKnownFit: Bool

        /// Best available rating, 0 when none is known (sorts such titles last).
        var rating: Double { item.tmdbRating ?? item.communityRating ?? 0 }
    }

    private static func ranksHigher(_ a: Candidate, _ b: Candidate) -> Bool {
        if a.matchedGenres != b.matchedGenres { return a.matchedGenres > b.matchedGenres }
        if a.tasteScore != b.tasteScore { return a.tasteScore > b.tasteScore }
        if a.rating != b.rating { return a.rating > b.rating }
        if a.runtimeKnownFit != b.runtimeKnownFit { return a.runtimeKnownFit }
        let ay = a.item.year ?? .min, by = b.item.year ?? .min
        if ay != by { return ay > by }
        return a.item.title.lowercased() < b.item.title.lowercased()
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
