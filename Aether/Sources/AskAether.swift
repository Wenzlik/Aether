import Foundation
import AetherCore

/// Shared **Ask Aether** query logic, used by Search, Home, and Library so the
/// behaviour is identical everywhere: find titles by name *and* recommend when
/// the request reads as a vibe/genre/runtime ask.
///
/// Pure orchestration over `AetherCore` — the deterministic `RecommendationEngine`
/// + `RecommendationQueryParser` and the on-device `RecommendationConcierge`. The
/// model never sees the whole catalogue; it only re-ranks the engine's shortlist.
enum AskAether {

    /// Answer a free-text request against the connected sources.
    static func answer(query: String, sources: [any MediaSource]) async -> AskResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sources.isEmpty else {
            return AskResult(libraryMatches: [], recommendation: nil, query: trimmed)
        }

        let library = UnifiedLibrary(sources: sources, downloads: nil)
        let all = await library.unifiedItems(kind: .movie) + (await library.unifiedItems(kind: .show))

        // Direct title matches (diacritic- and case-insensitive) — Ask Aether
        // searches the library, not just recommends.
        let matches = all.filter {
            $0.title.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }

        // Recommend only when the request reads as a vibe/genre/runtime ask, or
        // when nothing matched by title — so a plain title lookup ("Inception")
        // isn't paired with an unrelated suggestion.
        let request = RecommendationQueryParser().parse(
            trimmed, availableGenres: RecommendationEngine().availableGenres(in: all)
        )
        let hasRecIntent = !request.genres.isEmpty || request.type != nil || request.maxRuntime != nil
        var recommendation: RecommendationResult?
        if hasRecIntent || matches.isEmpty {
            recommendation = await RecommendationConcierge().recommend(query: trimmed, in: all)
        }

        return AskResult(libraryMatches: matches, recommendation: recommendation, query: trimmed)
    }
}
