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

@Suite("Recommendation candidate context — cast, director, content rating")
struct CandidateContextTests {

    // MARK: - Factory

    private func media(
        source: MediaSourceID = .plex(serverID: "s"),
        cast: [CastMember] = [],
        contentRating: String? = nil
    ) -> MediaItem {
        MediaItem(
            id: .init(source: source, rawValue: "1"),
            title: "T",
            kind: .movie,
            cast: cast,
            contentRating: contentRating
        )
    }

    private func unified(
        id: String = "m1",
        title: String = "First Man",
        year: Int? = 2018,
        overview: String? = "The story of Neil Armstrong.",
        tmdb: Double? = 7.5,
        cast: [CastMember] = [],
        contentRating: String? = nil
    ) -> UnifiedMediaItem {
        UnifiedMediaItem(
            id: id, title: title, year: year, overview: overview,
            posterURL: nil, backdropURL: nil, type: .movie,
            sources: [UnifiedSource(kind: .plex, item: media(cast: cast, contentRating: contentRating))],
            tmdbRating: tmdb
        )
    }

    private let firstManCast = [
        CastMember(id: "1", name: "Ryan Gosling", role: "Neil Armstrong"),
        CastMember(id: "2", name: "Claire Foy", role: nil),
        CastMember(id: "3", name: "Damien Chazelle", role: "Director"),
        CastMember(id: "4", name: "Josh Singer", role: "Writer")
    ]

    // MARK: - CastMember split

    @Test("Cast splits into actors and directors by billed role")
    func castSplit() {
        #expect(firstManCast.actors.map(\.name) == ["Ryan Gosling", "Claire Foy"])
        #expect(firstManCast.directors.map(\.name) == ["Damien Chazelle"])
    }

    // MARK: - Unified aggregation

    @Test("Unified cast + contentRating come from the first source (priority order) that carries them")
    func unifiedAggregation() {
        // Lead (plex) list item has neither; the jellyfin copy has both.
        let bare = media(source: .plex(serverID: "a"))
        let full = media(source: .jellyfin(serverID: "b"), cast: firstManCast, contentRating: "PG-13")
        let item = UnifiedMediaItem(
            id: "x", title: "T", year: nil, overview: nil,
            posterURL: nil, backdropURL: nil, type: .movie,
            sources: [UnifiedSource(kind: .plex, item: bare), UnifiedSource(kind: .jellyfin, item: full)]
        )
        #expect(item.cast.map(\.name) == firstManCast.map(\.name))
        #expect(item.contentRating == "PG-13")
    }

    @Test("No source with people ⇒ empty cast, nil contentRating")
    func unifiedAggregationEmpty() {
        let item = unified()
        #expect(item.cast.isEmpty)
        #expect(item.contentRating == nil)
    }

    // MARK: - Candidate lines

    @Test("Candidate line carries content rating, top cast, and director")
    func candidateLineFull() {
        let item = unified(cast: firstManCast, contentRating: "PG-13")
        let line = RecommendationConcierge.candidateLine(for: item)
        #expect(line.contains("rated PG-13"))
        #expect(line.contains("cast: Ryan Gosling, Claire Foy"))
        #expect(line.contains("director: Damien Chazelle"))
    }

    @Test("Candidate line without people or rating keeps the plain shape")
    func candidateLinePlain() {
        let line = RecommendationConcierge.candidateLine(for: unified())
        #expect(line == "id=m1 | First Man (2018) | rating 7.5 | The story of Neil Armstrong.")
    }

    @Test("Context cast backfills only when the item has none of its own")
    func candidateLineBackfill() {
        let backfill = CandidateContext(cast: [CastMember(id: "b", name: "Backfilled Actor")])
        // No own cast → the backfill shows.
        let bare = RecommendationConcierge.candidateLine(for: unified(), context: backfill)
        #expect(bare.contains("cast: Backfilled Actor"))
        // Own cast wins over the backfill.
        let own = RecommendationConcierge.candidateLine(for: unified(cast: firstManCast), context: backfill)
        #expect(own.contains("cast: Ryan Gosling"))
        #expect(!own.contains("Backfilled Actor"))
    }

    @Test("Cast and director lists are bounded (3 actors, 2 directors)")
    func candidateLineBounds() {
        let bigCast = (1...6).map { CastMember(id: "a\($0)", name: "Actor \($0)") }
            + (1...3).map { CastMember(id: "d\($0)", name: "Director \($0)", role: "Director") }
        let line = RecommendationConcierge.candidateLine(for: unified(cast: bigCast))
        #expect(line.contains("cast: Actor 1, Actor 2, Actor 3"))
        #expect(!line.contains("Actor 4"))
        #expect(line.contains("director: Director 1, Director 2"))
        #expect(!line.contains("Director 3"))
    }

    @Test("Keywords still ride the candidate line next to the new fields")
    func candidateLineKeywords() {
        let context = CandidateContext(keywords: ["space", "biopic"])
        let line = RecommendationConcierge.candidateLine(for: unified(contentRating: "PG-13"), context: context)
        #expect(line.contains("rated PG-13"))
        #expect(line.hasSuffix("| themes: space, biopic"))
    }
}
