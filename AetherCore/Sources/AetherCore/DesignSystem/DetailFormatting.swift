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

    /// True when `title` adds nothing beyond the season number — "Season 2",
    /// "Season", "Series 2", "Saison 2", or a bare number. Such titles are
    /// placeholders the source generated, not names worth surfacing.
    static func isGenericSeasonTitle(_ title: String) -> Bool {
        var rest = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.isEmpty { return true }
        for keyword in ["season", "series", "saison", "staffel", "temporada", "part", "volume", "vol", "chapter"] {
            if rest.hasPrefix(keyword) {
                rest = String(rest.dropFirst(keyword.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        // Generic when nothing meaningful remains after the keyword — empty, or
        // purely the season number ("Season 2" → "2", bare "2" → "2").
        return rest.isEmpty || rest.allSatisfy(\.isNumber)
    }

    /// "S1E3 · Title" when season + episode are known, else the bare title.
    public static func episodeLabel(_ episode: MediaItem) -> String {
        if let season = episode.seasonNumber, let number = episode.episodeNumber {
            return "S\(season)E\(number) · \(episode.title)"
        }
        return episode.title
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

    /// "Jul 26, 2007" — an air/release date for the metadata line. Fixed
    /// `en_US_POSIX` month-day-year so it reads the same everywhere (the app's UI
    /// strings are English) and stays deterministic for tests.
    public static func airDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMM d, yyyy"
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
