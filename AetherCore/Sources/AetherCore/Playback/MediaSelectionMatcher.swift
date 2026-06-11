import Foundation

/// Matches the user's selected source track (Plex / Jellyfin stream metadata)
/// against an `AVMediaSelectionGroup`'s options, by language then title (#68).
///
/// Pure and AVFoundation-free so it's unit-testable: callers flatten the
/// group's options into `(language, name)` pairs. Needed because in **direct
/// play** the server can't pick a track — the container ships with all of
/// them and the *player* must switch — and the source's language codes
/// (ISO 639-2 like "cze") rarely equal AVFoundation's BCP-47 tags ("cs").
public enum MediaSelectionMatcher {

    /// Index of the option best matching the desired track, or `nil` when
    /// nothing matches confidently (leave the player's default alone).
    ///
    /// Priority: primary-language match (normalized) → title containment
    /// tie-break within language matches → exact title match across all.
    public static func bestIndex(
        language: String?,
        title: String?,
        among options: [(language: String?, name: String)]
    ) -> Int? {
        let wantedLanguage = language.flatMap(normalizedLanguage)
        let wantedTitle = title?.lowercased()

        if let wantedLanguage {
            let languageMatches = options.indices.filter {
                options[$0].language.flatMap(normalizedLanguage) == wantedLanguage
            }
            if languageMatches.count == 1 { return languageMatches.first }
            if languageMatches.count > 1 {
                // Several tracks share the language (e.g. stereo + 5.1) — let
                // the title pick between them; else take the first.
                if let wantedTitle,
                   let refined = languageMatches.first(where: {
                       options[$0].name.lowercased().contains(wantedTitle)
                           || wantedTitle.contains(options[$0].name.lowercased())
                   }) {
                    return refined
                }
                return languageMatches.first
            }
        }

        // No language match — only trust an exact title match.
        if let wantedTitle {
            return options.firstIndex { $0.name.lowercased() == wantedTitle }
        }
        return nil
    }

    /// ISO 639-2 **bibliographic** codes → alpha-2. Foundation converts the
    /// terminological codes ("ces" → "cs") but not these legacy B-codes, which
    /// is exactly what Plex/FFmpeg-tagged files tend to carry.
    private static let bibliographicCodes: [String: String] = [
        "alb": "sq", "arm": "hy", "baq": "eu", "bur": "my", "chi": "zh",
        "cze": "cs", "dut": "nl", "fre": "fr", "geo": "ka", "ger": "de",
        "gre": "el", "ice": "is", "mac": "mk", "may": "ms", "per": "fa",
        "rum": "ro", "slo": "sk", "tib": "bo", "wel": "cy",
    ]

    /// Normalizes a language identifier to its primary subtag in alpha-2 where
    /// possible — "cze"/"ces"/"cs-CZ" → "cs", "eng"/"en-US" → "en" — so source
    /// codes and AVFoundation tags compare equal.
    static func normalizedLanguage(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if let mapped = bibliographicCodes[trimmed] { return mapped }
        let language = Locale.Language(identifier: trimmed)
        if let alpha2 = language.languageCode?.identifier(.alpha2) {
            return alpha2.lowercased()
        }
        // Unknown to Foundation — fall back to the primary subtag as-is.
        return trimmed.split(separator: "-").first.map(String.init)
    }
}
