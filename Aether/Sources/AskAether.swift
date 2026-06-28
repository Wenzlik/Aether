import Foundation
import AetherCore

/// Shared **Ask Aether** query logic, used by Search, Home, and Library so the
/// behaviour is identical everywhere: find titles **and people** by name *and*
/// recommend when the request reads as a vibe/genre/runtime ask.
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

        // Direct title matches (diacritic- and case-insensitive).
        let titleMatches = all.filter {
            $0.title.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        // Cast / director matches — "a film with Tom Hanks" or just "Tom Hanks".
        let peopleMatches = await peopleTitles(matching: trimmed, sources: sources)

        // Titles first, then person-derived (deduped by id).
        var seen = Set(titleMatches.map(\.id))
        let matches = titleMatches + peopleMatches.filter { seen.insert($0.id).inserted }

        // Recommend only when the request reads as a vibe/genre/runtime ask, or
        // when nothing matched by title/person — so a plain lookup ("Inception",
        // "Tom Hanks") isn't paired with an unrelated suggestion.
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

    // MARK: - People

    /// Titles whose cast or director matches the query, sorted by rating.
    ///
    /// Matches in both directions so it works for a bare name *and* a sentence:
    /// the person's name contains the query ("hanks" → Tom Hanks), or the query
    /// contains the full name ("a movie with tom hanks" → Tom Hanks). Bounded to
    /// a handful of people so a request never fans out into unbounded fetches.
    private static func peopleTitles(matching query: String, sources: [any MediaSource]) async -> [UnifiedMediaItem] {
        let q = query.lowercased()
        guard q.count >= 3 else { return [] }

        var hits: [(person: MediaPerson, source: any MediaSource)] = []
        for source in sources where source.supportsPeople {
            for kind in [PersonKind.actor, .director] {
                for person in await source.people(kind) {
                    let name = person.name.lowercased()
                    // Forward: typed a name fragment. Reverse: a full name (has a
                    // space) embedded in a sentence — avoids single-word noise.
                    if name.contains(q) || (name.contains(" ") && q.contains(name)) {
                        hits.append((person, source))
                    }
                }
            }
        }
        guard !hits.isEmpty else { return [] }

        var collected: [MediaItem] = []
        for hit in hits.prefix(8) {
            collected += await hit.source.items(withPerson: hit.person)
        }
        return UnifiedLibrary.merge(collected).sorted {
            ($0.tmdbRating ?? $0.communityRating ?? 0) > ($1.tmdbRating ?? $1.communityRating ?? 0)
        }
    }
}
