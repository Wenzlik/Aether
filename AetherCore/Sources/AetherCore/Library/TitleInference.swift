import Foundation

/// Pure, deterministic filename → metadata inference for sources that carry no
/// structured metadata of their own (Local Library #173, SMB/DLNA #172). Parses
/// a file/folder name into a clean title, year, and — for TV — season + episode.
///
/// No I/O, `Sendable`, fully unit-tested against a table of real-world names.
/// Each filesystem source feeds its filenames through this and maps the result
/// onto `MediaItem`.
public struct TitleInference: Sendable, Equatable {
    /// Cleaned, human-readable title (junk tokens + extension stripped).
    public let title: String
    public let year: Int?
    public let season: Int?
    public let episode: Int?

    /// True when both a season and an episode were found.
    public var isEpisode: Bool { season != nil && episode != nil }

    /// The `MediaItem.Kind` this parse implies — `.episode` when SxxExx-style
    /// numbering was found, else `.movie`.
    public var kind: MediaItem.Kind { isEpisode ? .episode : .movie }

    public init(title: String, year: Int? = nil, season: Int? = nil, episode: Int? = nil) {
        self.title = title
        self.year = year
        self.season = season
        self.episode = episode
    }

    /// Infer from a filename, optionally using its enclosing path components
    /// (e.g. `["Breaking Bad", "Season 01"]`) for season-folder hints and a
    /// title fallback when the filename alone is just an episode number.
    public init(filename: String, pathComponents: [String] = []) {
        let base = Self.stripExtension(filename)
        let normalized = Self.normalizeSeparators(base)

        // 1. Explicit episode marker (S01E02 / 1x02) inside the filename.
        if let ep = Self.matchEpisode(in: normalized) {
            let head = String(normalized[..<ep.index])
            self.init(
                title: Self.cleanTitle(head, fallback: pathComponents),
                year: Self.matchYear(in: head)?.value,
                season: ep.season,
                episode: ep.episode
            )
            return
        }

        // 2. A "Season NN" folder + a bare episode number in the filename.
        if let folderSeason = Self.seasonFromPath(pathComponents),
           let bare = Self.matchBareEpisode(in: normalized) {
            let head = String(normalized[..<bare.index])
            self.init(
                title: Self.cleanTitle(head, fallback: pathComponents),
                season: folderSeason,
                episode: bare.value
            )
            return
        }

        // 3. Movie: a release year.
        if let y = Self.matchYear(in: normalized) {
            self.init(
                title: Self.cleanTitle(String(normalized[..<y.index]), fallback: pathComponents),
                year: y.value
            )
            return
        }

        // 4. Nothing structured — clean the whole name.
        self.init(title: Self.cleanTitle(normalized, fallback: pathComponents))
    }

    // MARK: - Parsing

    private static let containerExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "mov", "avi", "ts", "m2ts", "webm", "wmv", "flv", "mpg", "mpeg", "ogm"
    ]

    /// Release-noise tokens. The title is truncated at the first of these (and
    /// they're dropped if they appear mid-name).
    private static let junkTokens: Set<String> = [
        "1080p", "720p", "2160p", "480p", "4k", "uhd", "hd", "sd",
        "x264", "x265", "h264", "h265", "hevc", "avc", "xvid", "divx", "10bit", "8bit",
        "bluray", "blu-ray", "bdrip", "brrip", "webrip", "web-dl", "webdl", "web",
        "hdtv", "dvdrip", "dvd", "remux", "hdr", "hdr10", "dv", "dolby", "vision",
        "aac", "ac3", "eac3", "dts", "dts-hd", "truehd", "atmos", "dd5", "ddp5", "flac", "mp3",
        "proper", "repack", "internal", "limited", "extended", "unrated", "remastered", "complete",
        "multi", "dual", "subbed", "dubbed"
    ]

    private static func stripExtension(_ filename: String) -> String {
        let ns = filename as NSString
        let ext = ns.pathExtension.lowercased()
        if containerExtensions.contains(ext) || (ext.count >= 2 && ext.count <= 4 && ext.allSatisfy(\.isLetter)) {
            return ns.deletingPathExtension
        }
        return filename
    }

    /// `_` and `.` (scene-style separators) → spaces; collapse runs of space.
    private static func normalizeSeparators(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "_", with: " ")
        out = out.replacingOccurrences(of: ".", with: " ")
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespaces)
    }

    private struct EpisodeMatch { let index: String.Index; let season: Int; let episode: Int }
    private struct ValueMatch { let index: String.Index; let value: Int }

    /// SxxExx (also `S01.E02`, `S1 E2`) or NxNN (`1x02`). Returns the earliest.
    private static func matchEpisode(in s: String) -> EpisodeMatch? {
        var best: EpisodeMatch?
        func consider(_ index: String.Index, _ season: Int, _ episode: Int) {
            if best == nil || index < best!.index {
                best = EpisodeMatch(index: index, season: season, episode: episode)
            }
        }
        if let m = s.firstMatch(of: /[Ss](\d{1,2})[\s._-]*[Ee](\d{1,3})/),
           let se = Int(m.1), let ep = Int(m.2) {
            consider(m.range.lowerBound, se, ep)
        }
        // NxNN — `\b\d{1,2}x\d{1,3}\b` never matches a resolution like 1920x1080
        // (the leading number is only 1–2 digits).
        if let m = s.firstMatch(of: /\b(\d{1,2})[xX](\d{1,3})\b/),
           let se = Int(m.1), let ep = Int(m.2) {
            consider(m.range.lowerBound, se, ep)
        }
        return best
    }

    /// A release year, preferring a parenthesised one (`(2019)`).
    private static func matchYear(in s: String) -> ValueMatch? {
        if let m = s.firstMatch(of: /\((19\d{2}|20\d{2})\)/), let v = Int(m.1) {
            return ValueMatch(index: m.range.lowerBound, value: v)
        }
        if let m = s.firstMatch(of: /\b(19\d{2}|20\d{2})\b/), let v = Int(m.1) {
            return ValueMatch(index: m.range.lowerBound, value: v)
        }
        return nil
    }

    /// A bare episode number used with a season-folder hint: `E02`, `Episode 2`,
    /// or a leading number (`02 - Title`).
    private static func matchBareEpisode(in s: String) -> ValueMatch? {
        if let m = s.firstMatch(of: /[Ee]pisode\s*(\d{1,3})/), let v = Int(m.1) {
            return ValueMatch(index: m.range.lowerBound, value: v)
        }
        if let m = s.firstMatch(of: /\b[Ee](\d{1,3})\b/), let v = Int(m.1) {
            return ValueMatch(index: m.range.lowerBound, value: v)
        }
        if let m = s.firstMatch(of: /^\s*(\d{1,3})\b/), let v = Int(m.1) {
            return ValueMatch(index: m.range.lowerBound, value: v)
        }
        return nil
    }

    /// Season number from a `Season 01` / `S01` path component.
    private static func seasonFromPath(_ components: [String]) -> Int? {
        for comp in components.reversed() {
            if let m = comp.firstMatch(of: /[Ss]eason\s*(\d{1,2})/), let v = Int(m.1) { return v }
            if let m = comp.firstMatch(of: /^[Ss](\d{1,2})$/), let v = Int(m.1) { return v }
        }
        return nil
    }

    /// Strip bracketed groups + release noise; truncate at the first junk token;
    /// fall back to a meaningful path component when nothing readable remains.
    /// Whether a path component looks like a "Season 01" / "S01" folder.
    private static func isSeasonFolder(_ s: String) -> Bool {
        s.firstMatch(of: /^[Ss](eason)?\s*\d/) != nil
    }

    private static func cleanTitle(_ raw: String, fallback components: [String]) -> String {
        var s = raw.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\([^\)]*\)"#, with: " ", options: .regularExpression)

        let tokens = s.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "." || $0 == "_" })
            .map(String.init)
        var kept: [String] = []
        for token in tokens {
            if junkTokens.contains(token.lowercased()) { break }
            kept.append(token)
        }
        let title = kept.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if !title.isEmpty { return title }

        // Fallback: the nearest non-"Season" path component (the show/folder name).
        for comp in components.reversed() {
            if isSeasonFolder(comp) { continue }   // skip season folders
            let cleaned = cleanTitle(normalizeSeparators(comp), fallback: [])
            if !cleaned.isEmpty { return cleaned }
        }
        return "Untitled"
    }
}
