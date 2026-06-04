import Foundation

/// Curated list of audio / subtitle languages exposed in Settings'
/// default-language pickers. Not exhaustive — a deliberately short shortlist
/// of the languages Aether's likely users encounter, keyed by BCP-47 codes
/// matching what Plex / Jellyfin tag streams with (`MediaItem.audioStreams`
/// `language` / `languageCode`). The picker also includes "Follow source
/// default" (`nil`) and, for subtitles only, an "Off" sentinel.
///
/// Add languages here as users ask for them; resist letting it bloat into
/// every ISO-639 code, since the screen is a settings picker, not a
/// language reference manual.
public struct PlaybackLanguage: Sendable, Hashable {
    /// BCP-47 code, lowercased — e.g. `"en"`, `"cs"`. Matched
    /// case-insensitively against stream `language` / `languageCode` values.
    public let code: String
    /// User-facing name in English. Localised display would mean parking a
    /// per-language localisation effort on top of feature work; deferred
    /// until the rest of the app gets localised too.
    public let displayName: String

    public init(code: String, displayName: String) {
        self.code = code
        self.displayName = displayName
    }

    /// The shortlist surfaced in pickers, sorted by display name.
    public static let common: [PlaybackLanguage] = [
        .init(code: "cs", displayName: "Czech"),
        .init(code: "nl", displayName: "Dutch"),
        .init(code: "en", displayName: "English"),
        .init(code: "fr", displayName: "French"),
        .init(code: "de", displayName: "German"),
        .init(code: "it", displayName: "Italian"),
        .init(code: "ja", displayName: "Japanese"),
        .init(code: "ko", displayName: "Korean"),
        .init(code: "pl", displayName: "Polish"),
        .init(code: "pt", displayName: "Portuguese"),
        .init(code: "ru", displayName: "Russian"),
        .init(code: "sk", displayName: "Slovak"),
        .init(code: "es", displayName: "Spanish"),
        .init(code: "uk", displayName: "Ukrainian"),
        .init(code: "zh", displayName: "Chinese")
    ]

    /// Resolves a BCP-47 code (case-insensitive) to its display name from
    /// `common`. Returns the upper-cased code when the language isn't in
    /// the shortlist — keeps the row from rendering blank for an "exotic"
    /// stream tag while still signalling what's set.
    public static func displayName(for code: String) -> String {
        let lower = code.lowercased()
        if let match = common.first(where: { $0.code == lower }) {
            return match.displayName
        }
        return code.uppercased()
    }
}
