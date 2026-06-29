import Testing
import Foundation
@testable import AetherCore

@Suite("RecommendationEngine (0.9 Apple Intelligence)")
struct RecommendationEngineTests {

    private let engine = RecommendationEngine()

    // MARK: - Factory

    private func item(
        _ title: String,
        type: MediaItem.Kind = .movie,
        genres: [String] = [],
        tmdb: Double? = nil,
        community: Double? = nil,
        runtimeMinutes: Int? = nil,
        watched: Bool = false,
        year: Int? = 2020
    ) -> UnifiedMediaItem {
        let runtime: Duration? = runtimeMinutes.map { .seconds($0 * 60) }
        let media = MediaItem(
            id: .init(source: .plex(serverID: "s"), rawValue: title),
            title: title,
            kind: type,
            runtime: runtime,
            isWatched: watched,
            genres: genres
        )
        return UnifiedMediaItem(
            id: title,
            title: title,
            year: year,
            overview: nil,
            posterURL: nil,
            backdropURL: nil,
            type: type,
            sources: [UnifiedSource(kind: .plex, item: media)],
            genres: genres,
            communityRating: community,
            tmdbRating: tmdb
        )
    }

    private func titles(_ items: [UnifiedMediaItem]) -> [String] { items.map(\.title) }

    // MARK: - Genre filter

    @Test("Only titles matching a requested genre are returned (case-insensitive)")
    func genreFilter() {
        let library = [
            item("Hereditary", genres: ["Horror"], tmdb: 7),
            item("Toy Story", genres: ["Animation", "Family"], tmdb: 8),
            item("The Thing", genres: ["Horror", "Sci-Fi"], tmdb: 8),
        ]
        let result = engine.recommend(from: library, request: .init(genres: ["horror"]))
        #expect(Set(titles(result)) == ["Hereditary", "The Thing"])
    }

    @Test("No requested genres ⇒ every title is eligible")
    func noGenreFilterReturnsAll() {
        let library = [item("A", genres: ["Horror"], tmdb: 5), item("B", genres: ["Comedy"], tmdb: 6)]
        let result = engine.recommend(from: library, request: .init())
        #expect(Set(titles(result)) == ["A", "B"])
    }

    // MARK: - Ranking

    @Test("Titles are ranked by best available rating, descending")
    func ranksByRating() {
        let library = [
            item("Low", genres: ["Horror"], tmdb: 4),
            item("High", genres: ["Horror"], tmdb: 9),
            item("Mid", genres: ["Horror"], tmdb: 6),
        ]
        let result = engine.recommend(from: library, request: .init(genres: ["Horror"]))
        #expect(titles(result) == ["High", "Mid", "Low"])
    }

    @Test("tmdbRating is preferred over communityRating")
    func tmdbPreferredOverCommunity() {
        // X: tmdb 8 wins over its own community 2; Y has only community 5.
        // If community were used for X, Y (5) would sort first.
        let library = [
            item("X", genres: ["Horror"], tmdb: 8, community: 2),
            item("Y", genres: ["Horror"], community: 5),
        ]
        let result = engine.recommend(from: library, request: .init(genres: ["Horror"]))
        #expect(titles(result) == ["X", "Y"])
    }

    @Test("Matching more requested genres outranks a higher rating")
    func genreMatchCountOutranksRating() {
        let library = [
            item("Broad", genres: ["Horror", "Thriller"], tmdb: 5),
            item("Narrow", genres: ["Horror"], tmdb: 9),
        ]
        let result = engine.recommend(from: library, request: .init(genres: ["Horror", "Thriller"]))
        #expect(titles(result) == ["Broad", "Narrow"])
    }

    @Test("Ties (same genre match + rating) fall back to a stable title order")
    func stableTieBreak() {
        let library = [
            item("Banshee", genres: ["Horror"], tmdb: 7, year: 2020),
            item("Apparition", genres: ["Horror"], tmdb: 7, year: 2020),
        ]
        let result = engine.recommend(from: library, request: .init(genres: ["Horror"]))
        #expect(titles(result) == ["Apparition", "Banshee"])
    }

    // MARK: - Runtime filter

    @Test("maxRuntime excludes titles whose known runtime exceeds the cap")
    func maxRuntimeExcludesTooLong() {
        let library = [
            item("Short", genres: ["Horror"], tmdb: 5, runtimeMinutes: 90),
            item("Epic", genres: ["Horror"], tmdb: 9, runtimeMinutes: 200),
        ]
        let result = engine.recommend(
            from: library,
            request: .init(genres: ["Horror"], maxRuntime: .seconds(120 * 60))
        )
        #expect(titles(result) == ["Short"])
    }

    @Test("Unknown runtime is kept under a maxRuntime cap, but ranks below a known fit")
    func unknownRuntimeKeptButRanksLower() {
        let library = [
            item("Known", genres: ["Horror"], tmdb: 7, runtimeMinutes: 100),
            item("Unknown", genres: ["Horror"], tmdb: 7, runtimeMinutes: nil),
        ]
        let result = engine.recommend(
            from: library,
            request: .init(genres: ["Horror"], maxRuntime: .seconds(120 * 60))
        )
        // Same genre match + rating, so the known-fit runtime breaks the tie.
        #expect(titles(result) == ["Known", "Unknown"])
    }

    // MARK: - Watched filter

    @Test("excludeWatched drops fully-watched titles by default")
    func excludeWatchedByDefault() {
        let library = [
            item("Seen", genres: ["Horror"], tmdb: 9, watched: true),
            item("Unseen", genres: ["Horror"], tmdb: 5, watched: false),
        ]
        let result = engine.recommend(from: library, request: .init(genres: ["Horror"]))
        #expect(titles(result) == ["Unseen"])
    }

    @Test("excludeWatched=false keeps watched titles")
    func keepWatchedWhenRequested() {
        let library = [
            item("Seen", genres: ["Horror"], tmdb: 9, watched: true),
            item("Unseen", genres: ["Horror"], tmdb: 5, watched: false),
        ]
        let result = engine.recommend(
            from: library,
            request: .init(genres: ["Horror"], excludeWatched: false)
        )
        #expect(titles(result) == ["Seen", "Unseen"])
    }

    // MARK: - Type filter

    @Test("type filter restricts to movies or shows")
    func typeFilter() {
        let library = [
            item("A Movie", type: .movie, genres: ["Horror"], tmdb: 6),
            item("A Show", type: .show, genres: ["Horror"], tmdb: 9),
        ]
        let movies = engine.recommend(from: library, request: .init(genres: ["Horror"], type: .movie))
        #expect(titles(movies) == ["A Movie"])
        let shows = engine.recommend(from: library, request: .init(genres: ["Horror"], type: .show))
        #expect(titles(shows) == ["A Show"])
    }

    // MARK: - Limit & edges

    @Test("limit caps the shortlist size")
    func limitCaps() {
        let library = (1...10).map { item("M\($0)", genres: ["Horror"], tmdb: Double($0)) }
        let result = engine.recommend(from: library, request: .init(genres: ["Horror"], limit: 3))
        #expect(result.count == 3)
        #expect(titles(result) == ["M10", "M9", "M8"])
    }

    @Test("limit of zero or less returns nothing")
    func nonPositiveLimit() {
        let library = [item("A", genres: ["Horror"], tmdb: 5)]
        #expect(engine.recommend(from: library, request: .init(limit: 0)).isEmpty)
    }

    @Test("Empty library returns no recommendations")
    func emptyLibrary() {
        #expect(engine.recommend(from: [], request: .init(genres: ["Horror"])).isEmpty)
    }

    // MARK: - availableGenres

    @Test("availableGenres dedups case-insensitively and sorts")
    func availableGenresDedupSorted() {
        let library = [
            item("A", genres: ["Horror", "Thriller"]),
            item("B", genres: ["horror", "Comedy"]),
            item("C", genres: ["Sci-Fi"]),
        ]
        let genres = engine.availableGenres(in: library)
        // "Horror"/"horror" collapse to one (first-seen casing kept); sorted.
        #expect(genres == ["Comedy", "Horror", "Sci-Fi", "Thriller"])
    }
}

@Suite("TasteProfile + recommended (Discover hero)")
struct TasteProfileTests {

    private let engine = RecommendationEngine()

    private func item(
        _ title: String,
        genres: [String],
        watched: Bool = false,
        tmdb: Double? = nil,
        type: MediaItem.Kind = .movie
    ) -> UnifiedMediaItem {
        let media = MediaItem(
            id: .init(source: .plex(serverID: "s"), rawValue: title),
            title: title,
            kind: type,
            runtime: nil,
            isWatched: watched,
            genres: genres
        )
        return UnifiedMediaItem(
            id: title,
            title: title,
            year: 2020,
            overview: nil,
            posterURL: nil,
            backdropURL: nil,
            type: type,
            sources: [UnifiedSource(kind: .plex, item: media)],
            genres: genres,
            communityRating: nil,
            tmdbRating: tmdb
        )
    }

    @Test("Profile weights genres of watched titles; ignores unwatched")
    func profileFromWatched() {
        let library = [
            item("Seen A", genres: ["Horror"], watched: true),
            item("Seen B", genres: ["Horror", "Thriller"], watched: true),
            item("Unseen", genres: ["Comedy"]),
        ]
        let profile = TasteProfile.from(library: library)
        #expect(!profile.isEmpty)
        #expect((profile.genreWeights["Horror"] ?? 0) > (profile.genreWeights["Thriller"] ?? 0))
        #expect(profile.genreWeights["Comedy"] == nil)
    }

    @Test("Recommended ranks unwatched by taste overlap and excludes watched")
    func recommendedRanksByTaste() {
        let library = [
            item("Watched Horror", genres: ["Horror"], watched: true),
            item("Unseen Horror", genres: ["Horror"], tmdb: 6),
            item("Unseen Comedy", genres: ["Comedy"], tmdb: 9),
        ]
        let picks = engine.recommended(
            from: library, profile: .from(library: library), limit: 10
        )
        #expect(picks.map(\.title) == ["Unseen Horror"])
    }

    @Test("Empty profile falls back to best-rated unwatched")
    func emptyProfileFallsBackToRating() {
        let library = [
            item("Low", genres: ["Drama"], tmdb: 5),
            item("High", genres: ["Drama"], tmdb: 9),
        ]
        let profile = TasteProfile.from(library: library)
        #expect(profile.isEmpty)
        let picks = engine.recommended(from: library, profile: profile, limit: 1)
        #expect(picks.first?.title == "High")
    }

    @Test("No genre overlap falls back to best-rated")
    func noOverlapFallsBackToRating() {
        let library = [
            item("Seen", genres: ["Horror"], watched: true),
            item("Unseen Low", genres: ["Comedy"], tmdb: 4),
            item("Unseen High", genres: ["Drama"], tmdb: 8),
        ]
        let picks = engine.recommended(
            from: library, profile: .from(library: library), limit: 1
        )
        #expect(picks.first?.title == "Unseen High")
    }
}
