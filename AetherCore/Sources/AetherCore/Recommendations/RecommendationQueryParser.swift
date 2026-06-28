import Foundation

/// Deterministic natural-language → `RecommendationRequest` parser.
///
/// This is the **fallback** path used wherever the Foundation Models concierge
/// can't run — tvOS (no Apple Intelligence), older devices, or when on-device
/// inference fails. It's pure, `Sendable`, and fully unit-tested, so the feature
/// always degrades to *something* sensible rather than nothing.
///
/// It only recognizes genres the library actually has (passed in via
/// `availableGenres`), a media type, and a runtime cap — everything the
/// deterministic `RecommendationEngine` can act on.
public struct RecommendationQueryParser: Sendable {
    public init() {}

    public func parse(
        _ query: String,
        availableGenres: [String],
        limit: Int = 15
    ) -> RecommendationRequest {
        let lower = query.lowercased()
        let words = Set(lower.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        // Case-insensitive lookup back to the catalogue's own casing.
        let byLowerName = Dictionary(
            availableGenres.map { ($0.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var picked: [String] = []
        func add(_ genre: String) { if !picked.contains(genre) { picked.append(genre) } }

        // 1. Direct genre mentions ("a horror", "sci-fi movie").
        for genre in availableGenres where lower.contains(genre.lowercased()) { add(genre) }

        // 2. Mood synonyms → the matching catalogue genre, if present.
        for (mood, candidates) in Self.moodToGenres where words.contains(mood) {
            for candidate in candidates {
                if let actual = byLowerName[candidate.lowercased()] { add(actual) }
            }
        }

        // 3. Media type.
        var type: MediaItem.Kind?
        if !words.isDisjoint(with: ["show", "shows", "series", "tv"]) {
            type = .show
        } else if !words.isDisjoint(with: ["movie", "movies", "film", "films"]) {
            type = .movie
        }

        // 4. Runtime cap ("under 2 hours", "90 min", "2h").
        let maxRuntime = Self.parseRuntime(
            lower.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        )

        return RecommendationRequest(
            genres: picked,
            type: type,
            maxRuntime: maxRuntime,
            excludeWatched: true,
            limit: limit
        )
    }

    // MARK: - Runtime

    static func parseRuntime(_ words: [String]) -> Duration? {
        for (index, word) in words.enumerated() {
            // Separated form: "2" "hours" / "90" "minutes".
            if let n = Int(word), n > 0, index + 1 < words.count {
                let unit = words[index + 1]
                if unit.hasPrefix("hour") || unit.hasPrefix("hr") { return .seconds(n * 3600) }
                if unit.hasPrefix("min") { return .seconds(n * 60) }
            }
            // Glued form: "2h" / "90min" / "2hrs".
            if let glued = gluedRuntime(word) { return glued }
        }
        return nil
    }

    private static func gluedRuntime(_ word: String) -> Duration? {
        let digits = word.prefix { $0.isNumber }
        guard !digits.isEmpty, let n = Int(digits), n > 0 else { return nil }
        let unit = word.dropFirst(digits.count)
        guard !unit.isEmpty else { return nil }
        if unit.hasPrefix("h") { return .seconds(n * 3600) }
        if unit.hasPrefix("m") { return .seconds(n * 60) }
        return nil
    }

    // MARK: - Mood vocabulary

    /// Mood word → acceptable catalogue genre names (multiple spellings, since
    /// Plex says "Sci-Fi" and TMDb/Jellyfin say "Science Fiction"). Only added
    /// when the library actually carries one of them.
    static let moodToGenres: [String: [String]] = [
        "scary": ["Horror"], "spooky": ["Horror"], "creepy": ["Horror"],
        "terrifying": ["Horror"], "frightening": ["Horror"],
        "funny": ["Comedy"], "hilarious": ["Comedy"], "lighthearted": ["Comedy"],
        "romantic": ["Romance"],
        "suspenseful": ["Thriller"], "tense": ["Thriller"], "gripping": ["Thriller"],
        "explosive": ["Action"], "adrenaline": ["Action"],
        "futuristic": ["Science Fiction", "Sci-Fi"],
        "animated": ["Animation"], "cartoon": ["Animation"],
        "magical": ["Fantasy"],
        "emotional": ["Drama"], "dramatic": ["Drama"],
        "factual": ["Documentary"],
        "kids": ["Family"], "wholesome": ["Family"],
    ]
}
