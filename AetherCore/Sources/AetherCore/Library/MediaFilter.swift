import Foundation

/// A library/search filter (#295). Currently just audio language; structured so
/// more facets (resolution, HDR, …) can join without changing call sites.
public struct MediaFilter: Equatable, Sendable, Codable {
    /// Canonical audio-language code to filter by (see `AudioLanguage`), or
    /// `nil` for no audio-language filter.
    public var audioLanguage: String?

    public init(audioLanguage: String? = nil) {
        self.audioLanguage = audioLanguage
    }

    public static let none = MediaFilter()

    /// Whether any facet is active (drives the Filters control's badge).
    public var isActive: Bool { audioLanguage != nil }

    /// Does `item` satisfy the filter using **only locally-available** data
    /// (its audio tracks)? Used for sources that don't filter server-side
    /// (Jellyfin carries audio tracks in its list responses). A source with no
    /// track data on an item can't match a specific language — honest "unknown".
    public func matchesLocally(_ item: MediaItem) -> Bool {
        guard let audioLanguage else { return true }
        return item.audioTracks.contains {
            AudioLanguage.canonical($0.languageCode) == audioLanguage
        }
    }
}

/// One selectable audio language — a canonical code for matching plus a
/// localized name for display (#295).
public struct AudioLanguageOption: Hashable, Sendable, Codable, Identifiable {
    /// Canonical matching key (see `AudioLanguage.canonical`).
    public let code: String
    /// Localized human name, e.g. "English", "Czech".
    public let displayName: String

    public init(code: String, displayName: String) {
        self.code = code
        self.displayName = displayName
    }

    public var id: String { code }
}

/// Normalizes the many forms of language codes the sources emit (ISO 639-1
/// 2-letter, 639-2/B and /T 3-letter, free text) to a single canonical key so
/// the same language matches across Plex and Jellyfin, and produces a localized
/// display name (#295).
public enum AudioLanguage {
    /// Marker for unknown / undetermined audio language.
    public static let unknown = "und"

    /// ISO 639-2 (bibliographic *and* terminological) → 639-1, for the codes
    /// where the two diverge or a 3-letter is common in media metadata. Plex
    /// tends to emit 639-2/B (`cze`, `ger`, `fre`), Jellyfin 639-2/T (`ces`,
    /// `deu`, `fra`); both fold to the 2-letter key here.
    private static let iso3to1: [String: String] = [
        "eng": "en",
        "ces": "cs", "cze": "cs",
        "ger": "de", "deu": "de",
        "fre": "fr", "fra": "fr",
        "spa": "es",
        "ita": "it",
        "por": "pt",
        "rus": "ru",
        "pol": "pl",
        "nld": "nl", "dut": "nl",
        "jpn": "ja",
        "kor": "ko",
        "chi": "zh", "zho": "zh",
        "swe": "sv",
        "nor": "no",
        "dan": "da",
        "fin": "fi",
        "hun": "hu",
        "tur": "tr",
        "ara": "ar",
        "heb": "he",
        "hin": "hi",
        "tha": "th",
        "ukr": "uk",
        "ell": "el", "gre": "el",
        "ron": "ro", "rum": "ro",
        "slk": "sk", "slo": "sk",
        "bul": "bg",
        "hrv": "hr",
        "srp": "sr",
        "vie": "vi",
        "ind": "id",
    ]

    /// Canonical key for a raw language value. Empty / `und` / unrecognized
    /// short codes pass through lowercased so they still group consistently.
    public static func canonical(_ raw: String?) -> String {
        guard let raw else { return unknown }
        let lower = raw.lowercased().trimmingCharacters(in: .whitespaces)
        guard !lower.isEmpty else { return unknown }
        if lower == "und" || lower == "unknown" { return unknown }
        if lower.count == 2 { return lower }
        if let mapped = iso3to1[lower] { return mapped }
        return lower
    }

    /// A localized display name for a canonical code, e.g. `en` → "English".
    /// Falls back to the uppercased code when the system can't localize it.
    public static func displayName(for code: String) -> String {
        if code == unknown { return "Unknown" }
        if let name = Locale.current.localizedString(forLanguageCode: code), !name.isEmpty {
            return name.capitalized(with: .current)
        }
        return code.uppercased()
    }

    /// Build a deduplicated, display-sorted option list from raw codes, dropping
    /// `unknown` (it isn't a useful filter target — issue #295).
    public static func options(fromRawCodes codes: [String?]) -> [AudioLanguageOption] {
        var seen: Set<String> = []
        var options: [AudioLanguageOption] = []
        for raw in codes {
            let code = canonical(raw)
            guard code != unknown, seen.insert(code).inserted else { continue }
            options.append(AudioLanguageOption(code: code, displayName: displayName(for: code)))
        }
        return options.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}
