import Foundation

/// Pure presentation formatting for the Detail screen — kind/season/episode
/// labels, runtime / position strings, and the technical Media-Info lines.
///
/// Extracted from the large `DetailView` so this logic is **unit-testable in
/// isolation** rather than buried in a SwiftUI view (#241). All functions are
/// pure (input → string), no view or async state.
public enum DetailFormatting {

    // MARK: - Labels

    public static func kindLabel(_ kind: MediaItem.Kind) -> String {
        switch kind {
        case .movie: return "Movie"
        case .episode: return "Episode"
        case .show: return "Series"
        case .season: return "Season"
        }
    }

    /// A season's display label that prefers a **real, human name** over the
    /// bare number.
    ///
    /// Plex/Jellyfin frequently expose only a generic "Season 2" title; when
    /// that's all we have we keep "Season 2". But when the source carries an
    /// actual name (e.g. "Asylum"), we surface it alongside the number as
    /// "S2 · Asylum" — the evocative name without losing the ordering, which
    /// is exactly what anthology shows like American Horror Story need (#263).
    public static func seasonLabel(_ season: MediaItem) -> String {
        let number = season.seasonNumber
        let title = season.title.trimmingCharacters(in: .whitespacesAndNewlines)

        // A title is a *real* season name only when it's non-empty, isn't the
        // generic "Season N", and isn't just the series name repeated (some
        // metadata agents set the season's title to the show's title).
        let isSeriesName = title.caseInsensitiveCompare(season.seriesTitle ?? "") == .orderedSame
        if !title.isEmpty, !isGenericSeasonTitle(title), !isSeriesName {
            if let number { return "S\(number) · \(title)" }
            return title
        }
        if let number { return "Season \(number)" }
        return title.isEmpty ? "Season" : title
    }

    /// Localized "season" words a server may use as the generic title —
    /// compared diacritic-folded, so "řada" / "série" / "sezóna" match too.
    /// Plex localizes season titles per its server language ("2. řada"), which
    /// used to slip past the English-only prefix check and render as a "name".
    private static let genericSeasonWords: Set<String> = [
        "season", "seasons", "series", "serie", "saison", "staffel",
        "temporada", "stagione", "seizoen", "sezona", "sezon", "rada",
        "part", "volume", "vol", "chapter",
    ]

    /// True when `title` adds nothing beyond the season number — "Season 2",
    /// "2. řada", "Série 1", "Vol. 3", or a bare number. Such titles are
    /// placeholders the source generated, not names worth surfacing.
    static func isGenericSeasonTitle(_ title: String) -> Bool {
        // Fold case + diacritics, then keep only letters — "2. řada" → "rada",
        // "Season 2" → "season" — and test against the generic vocabulary.
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let letters = folded.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let word = String(String.UnicodeScalarView(letters))
        return word.isEmpty || genericSeasonWords.contains(word)
    }

    /// "S1E3 · Title" when season + episode are known, else the bare title.
    public static func episodeLabel(_ episode: MediaItem) -> String {
        if let season = episode.seasonNumber, let number = episode.episodeNumber {
            return "S\(season)E\(number) · \(episode.title)"
        }
        return episode.title
    }

    /// Label for a Continue Watching card. For a series episode, identifies it
    /// across shows: "American Dad! · S1E5 · Roger Codger" (or "S1E5 · Roger
    /// Codger" when the show name is unknown). Movies / standalone items fall
    /// back to the bare title. (#339)
    public static func continueWatchingLabel(_ item: MediaItem) -> String {
        guard let season = item.seasonNumber, let number = item.episodeNumber else {
            return item.title
        }
        let code = "S\(season)E\(number) · \(item.title)"
        if let show = item.seriesTitle, !show.isEmpty {
            return "\(show) · \(code)"
        }
        return code
    }

    /// "S1 • E2 - Ladies Room" — the episode-context line shown beneath the
    /// **series** title on an episode's Detail hero (the series name is the big
    /// title; this carries the season/episode + episode name). Falls back to the
    /// bare title when the numbers are unknown.
    public static func episodeContext(_ episode: MediaItem) -> String {
        if let season = episode.seasonNumber, let number = episode.episodeNumber {
            return "S\(season) • E\(number) - \(episode.title)"
        }
        return episode.title
    }

    /// An air/release date for the metadata line, formatted for the **app
    /// language** (#320 root-cause c): pass the view's `\.locale` and the date
    /// reads "6. 6. 2005" in Čeština, "Jun 6, 2005" in English — a localized
    /// `.medium` style, not a fixed `en_US_POSIX` format.
    ///
    /// When `locale` is nil the legacy fixed `en_US_POSIX` "MMM d, yyyy" is used,
    /// keeping existing call sites + tests deterministic until they thread a
    /// locale through.
    public static func airDate(_ date: Date, locale: Locale? = nil) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        if let locale {
            formatter.locale = locale
            formatter.dateStyle = .medium
        } else {
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "MMM d, yyyy"
        }
        return formatter.string(from: date)
    }

    // MARK: - Durations & numbers

    public static func runtime(_ duration: Duration) -> String {
        let total = Int(seconds(duration))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    public static func position(_ duration: Duration) -> String {
        let total = Int(seconds(duration))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%02d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%02d:%02d", minutes, secs)
    }

    public static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    public static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    public static func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    public static func bitrate(_ kbps: Int) -> String {
        if kbps >= 1000 {
            return String(format: "%.1f Mbps", Double(kbps) / 1000.0)
        }
        return "\(kbps) kbps"
    }

    /// Channel count → loudspeaker layout: 2 → "2.0", 6 → "5.1", 8 → "7.1".
    public static func channelLabel(_ channels: Int) -> String {
        switch channels {
        case 1: return "Mono"
        case 2: return "2.0"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(channels) ch"
        }
    }

    // MARK: - Media-info lines

    /// "HEVC 4K" / "H.264" / "1080p" / nil — codec + resolution, each optional.
    public static func videoLine(_ info: MediaInfo?) -> String? {
        guard let info else { return nil }
        let codec = info.videoCodec?.uppercased()
        let resolution = info.videoResolution
        switch (codec, resolution) {
        case let (codec?, resolution?): return "\(codec) \(resolution)"
        case let (codec?, nil):         return codec
        case let (nil, resolution?):    return resolution
        case (nil, nil):                return nil
        }
    }

    /// "EAC3 5.1" / "AAC" / "2.0" / nil — codec + channel layout, each optional.
    public static func audioLine(_ info: MediaInfo?) -> String? {
        guard let info else { return nil }
        let codec = info.audioCodec?.uppercased()
        let channels = info.audioChannels.map { channelLabel($0) }
        switch (codec, channels) {
        case let (codec?, channels?): return "\(codec) \(channels)"
        case let (codec?, nil):       return codec
        case let (nil, channels?):    return channels
        case (nil, nil):              return nil
        }
    }

    public static func hdrBadge(_ info: MediaInfo?) -> String? {
        guard let info else { return nil }
        if info.isDolbyVision { return "Dolby Vision" }
        if info.isHDR { return "HDR" }
        return nil
    }

    /// A subtitle track's display name — localized language name, else its title.
    public static func subtitleName(_ track: MediaSubtitleTrack) -> String? {
        if let code = track.languageCode?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty {
            return Locale.current.localizedString(forLanguageCode: code) ?? code
        }
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }
}
