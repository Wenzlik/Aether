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

    /// "Season 2" from a season's number, or its title when the number is absent.
    public static func seasonLabel(_ season: MediaItem) -> String {
        if let number = season.seasonNumber { return "Season \(number)" }
        return season.title
    }

    /// "S1E3 · Title" when season + episode are known, else the bare title.
    public static func episodeLabel(_ episode: MediaItem) -> String {
        if let season = episode.seasonNumber, let number = episode.episodeNumber {
            return "S\(season)E\(number) · \(episode.title)"
        }
        return episode.title
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
