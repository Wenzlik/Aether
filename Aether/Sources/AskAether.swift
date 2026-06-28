import Foundation
import AetherCore

/// Shared **Ask Aether** query logic, used by Search, Home, and Library so the
/// behaviour is identical everywhere: find titles **and people** by name,
/// recommend when the request reads as a vibe/genre/runtime ask, and surface
/// **"more like this"** owned titles via TMDb.
///
/// Pure orchestration over `AetherCore` — the deterministic `RecommendationEngine`
/// + `RecommendationQueryParser`, the on-device `RecommendationConcierge`, and
/// (optionally) `TMDbClient` for richer grounding. The model never sees the whole
/// catalogue; it only re-ranks the engine's shortlist.
enum AskAether {

    /// Answer a free-text request against the connected sources.
    /// - Parameter tmdb: a configured TMDb client for "more like this" + keyword
    ///   grounding; pass `nil` to skip those (still fully functional).
    static func answer(
        query: String,
        sources: [any MediaSource],
        tmdb: TMDbClient? = nil
    ) async -> AskResult {
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

        // "More like this" — when the request points at an owned title (a plain
        // lookup, or "more like X"), surface owned TMDb recommendations.
        let (similar, similarTo) = await similarTitles(query: trimmed, in: all, tmdb: tmdb)

        // Recommend only when the request reads as a vibe/genre/runtime ask, or
        // when nothing else surfaced — so a plain lookup or a "more like X" isn't
        // paired with an unrelated suggestion.
        let request = RecommendationQueryParser().parse(
            trimmed, availableGenres: RecommendationEngine().availableGenres(in: all)
        )
        let hasRecIntent = !request.genres.isEmpty || request.type != nil || request.maxRuntime != nil
        var recommendation: RecommendationResult?
        if hasRecIntent || (matches.isEmpty && similar.isEmpty) {
            recommendation = await RecommendationConcierge().recommend(
                query: trimmed, in: all, enrich: keywordEnricher(tmdb)
            )
        }

        return AskResult(
            libraryMatches: matches,
            recommendation: recommendation,
            similar: similar,
            similarTo: similarTo,
            query: trimmed
        )
    }

    // MARK: - People

    /// Titles whose cast or director matches the query, sorted by rating.
    ///
    /// Matches in both directions so it works for a bare name *and* a sentence:
    /// the person's name contains the query ("hanks" → Tom Hanks), or the query
    /// contains the full name ("a movie with tom hanks" → Tom Hanks). Bounded to a
    /// handful of people so a request never fans out into unbounded fetches.
    private static func peopleTitles(matching query: String, sources: [any MediaSource]) async -> [UnifiedMediaItem] {
        let q = query.lowercased()
        guard q.count >= 3 else { return [] }

        var hits: [(person: MediaPerson, source: any MediaSource)] = []
        for source in sources where source.supportsPeople {
            for person in await AskAetherCache.shared.people(for: source) {
                let name = person.name.lowercased()
                if name.contains(q) || (name.contains(" ") && q.contains(name)) {
                    hits.append((person, source))
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

    // MARK: - More like this (TMDb)

    /// Owned titles TMDb considers similar to the title the request points at.
    /// Returns the matches plus the anchor's display title for the section header.
    private static func similarTitles(
        query: String,
        in all: [UnifiedMediaItem],
        tmdb: TMDbClient?
    ) async -> (items: [UnifiedMediaItem], anchorTitle: String?) {
        guard let tmdb, tmdb.isConfigured, let anchor = similarAnchor(query: query, in: all),
              let tmdbID = anchor.tmdbID.flatMap(Int.init) else {
            return ([], nil)
        }
        let ids = await tmdb.recommendations(tmdbID: tmdbID, type: anchor.isShow ? .tv : .movie)
        guard !ids.isEmpty else { return ([], nil) }

        // Index the library by TMDb id, then keep only owned recommendations.
        let ownedByTMDb = Dictionary(
            all.compactMap { item in item.tmdbID.flatMap(Int.init).map { ($0, item) } },
            uniquingKeysWith: { first, _ in first }
        )
        let owned = ids.compactMap { ownedByTMDb[$0] }.filter { $0.id != anchor.id }
        return owned.isEmpty ? ([], nil) : (owned, anchor.title)
    }

    /// The owned title a "more like this" request points at: an explicit
    /// "(more) like X" / "similar to X" phrase, otherwise a plain title lookup.
    /// `nil` for vibe/genre requests (no title in the query).
    private static func similarAnchor(query: String, in all: [UnifiedMediaItem]) -> UnifiedMediaItem? {
        let lowered = query.lowercased()
        var phrase = query
        for prefix in ["more like ", "something like ", "similar to ", "like "] where lowered.hasPrefix(prefix) {
            phrase = String(query.dropFirst(prefix.count))
            break
        }
        phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return nil }
        return all.first {
            $0.tmdbID != nil
                && $0.title.range(of: phrase, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    // MARK: - Keyword enrichment

    /// Build the concierge `enrich` hook: TMDb keyword tags for the shortlist,
    /// cached per title. `nil` when no TMDb client is configured.
    private static func keywordEnricher(
        _ tmdb: TMDbClient?
    ) -> (@Sendable ([UnifiedMediaItem]) async -> [String: [String]])? {
        guard let tmdb, tmdb.isConfigured else { return nil }
        return { shortlist in
            var map: [String: [String]] = [:]
            for item in shortlist.prefix(8) {
                let kw = await AskAetherCache.shared.keywords(for: item, tmdb: tmdb)
                if !kw.isEmpty { map[item.id] = Array(kw.prefix(6)) }
            }
            return map
        }
    }
}

/// Session cache for the network-heavy bits of Ask Aether — the per-source people
/// index and per-title TMDb keywords — so repeated asks don't refetch.
actor AskAetherCache {
    static let shared = AskAetherCache()

    private var peopleBySource: [String: [MediaPerson]] = [:]
    private var keywordsByID: [String: [String]] = [:]

    /// All people (cast + director) for a source, fetched once per session.
    func people(for source: any MediaSource) async -> [MediaPerson] {
        let key = source.id.stableKey
        if let cached = peopleBySource[key] { return cached }
        var all: [MediaPerson] = []
        for kind in [PersonKind.actor, .director] { all += await source.people(kind) }
        peopleBySource[key] = all
        return all
    }

    /// TMDb keywords for a title, fetched once per session.
    func keywords(for item: UnifiedMediaItem, tmdb: TMDbClient) async -> [String] {
        guard let tmdbID = item.tmdbID.flatMap(Int.init) else { return [] }
        let key = "\(item.isShow ? "tv" : "movie").\(tmdbID)"
        if let cached = keywordsByID[key] { return cached }
        let kw = await tmdb.keywords(tmdbID: tmdbID, type: item.isShow ? .tv : .movie)
        keywordsByID[key] = kw
        return kw
    }
}
