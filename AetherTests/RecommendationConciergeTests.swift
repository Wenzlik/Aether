import Testing
import Foundation
@testable import AetherCore

@Suite("Recommendation P2 — query parser, grounding, type mapping")
struct RecommendationConciergeTests {

    private let parser = RecommendationQueryParser()
    private let genres = ["Horror", "Comedy", "Science Fiction", "Thriller", "Family"]

    private func unified(_ id: String) -> UnifiedMediaItem {
        UnifiedMediaItem(
            id: id, title: id, year: nil, overview: nil,
            posterURL: nil, backdropURL: nil, type: .movie, sources: []
        )
    }

    // MARK: - Query parser: genres

    @Test("A direct genre mention is picked up")
    func directGenre() {
        #expect(parser.parse("recommend a horror", availableGenres: genres).genres == ["Horror"])
    }

    @Test("A mood word maps to the matching catalogue genre")
    func moodSynonym() {
        #expect(parser.parse("something really scary tonight", availableGenres: genres).genres == ["Horror"])
        #expect(parser.parse("a funny one", availableGenres: genres).genres == ["Comedy"])
    }

    @Test("Sci-fi mood resolves to the catalogue's own spelling")
    func sciFiSpelling() {
        // 'futuristic' offers both "Science Fiction" and "Sci-Fi"; this library
        // only has the former, so that's what comes back.
        #expect(parser.parse("something futuristic", availableGenres: genres).genres == ["Science Fiction"])
    }

    @Test("A mood whose genre the library lacks adds nothing")
    func moodWithoutGenre() {
        #expect(parser.parse("something magical", availableGenres: genres).genres.isEmpty)
    }

    // MARK: - Query parser: type

    @Test("Media type is detected from the phrasing")
    func typeDetection() {
        #expect(parser.parse("a funny show", availableGenres: genres).type == .show)
        #expect(parser.parse("a horror movie", availableGenres: genres).type == .movie)
        #expect(parser.parse("a horror", availableGenres: genres).type == nil)
    }

    // MARK: - Query parser: runtime

    @Test("Runtime cap is parsed from hours and minutes, separated or glued")
    func runtimeParsing() {
        #expect(parser.parse("a horror under 2 hours", availableGenres: genres).maxRuntime == .seconds(7200))
        #expect(parser.parse("a comedy 90 minutes", availableGenres: genres).maxRuntime == .seconds(5400))
        #expect(parser.parse("a thriller 90min", availableGenres: genres).maxRuntime == .seconds(5400))
        #expect(parser.parse("a thriller 2h", availableGenres: genres).maxRuntime == .seconds(7200))
    }

    @Test("No runtime phrase ⇒ no cap; a bare year is not a runtime")
    func noRuntime() {
        #expect(parser.parse("a horror", availableGenres: genres).maxRuntime == nil)
        #expect(parser.parse("a 2024 horror", availableGenres: genres).maxRuntime == nil)
    }

    @Test("A full request parses genre + type + runtime together")
    func combined() {
        let r = parser.parse("a scary movie under 2 hours", availableGenres: genres)
        #expect(r.genres == ["Horror"])
        #expect(r.type == .movie)
        #expect(r.maxRuntime == .seconds(7200))
        #expect(r.excludeWatched)
    }

    // MARK: - Grounding (resolve)

    @Test("A valid model id resolves to that exact shortlist item")
    func resolveValidID() {
        let list = [unified("a"), unified("b"), unified("c")]
        #expect(RecommendationConcierge.resolve(pickID: "b", in: list)?.id == "b")
    }

    @Test("An id outside the shortlist falls back to the top candidate (no hallucination)")
    func resolveInvalidID() {
        let list = [unified("a"), unified("b")]
        #expect(RecommendationConcierge.resolve(pickID: "ghost", in: list)?.id == "a")
    }

    @Test("Resolving against an empty shortlist returns nil")
    func resolveEmpty() {
        #expect(RecommendationConcierge.resolve(pickID: "a", in: []) == nil)
    }

    // MARK: - Type mapping

    @Test("Model's free-text media type maps to a concrete kind")
    func mediaKindMapping() {
        #expect(RecommendationConcierge.mediaKind(from: "movie") == .movie)
        #expect(RecommendationConcierge.mediaKind(from: "Shows") == .show)
        #expect(RecommendationConcierge.mediaKind(from: "series") == .show)
        #expect(RecommendationConcierge.mediaKind(from: "any") == nil)
        #expect(RecommendationConcierge.mediaKind(from: "banana") == nil)
    }

    // MARK: - Result

    @Test("An empty result reports isEmpty")
    func resultEmptiness() {
        let empty = RecommendationResult(pick: nil, reason: nil, shortlist: [], usedAI: false)
        #expect(empty.isEmpty)
        let full = RecommendationResult(pick: unified("a"), reason: "fits", shortlist: [unified("a")], usedAI: true)
        #expect(!full.isEmpty)
    }
}
