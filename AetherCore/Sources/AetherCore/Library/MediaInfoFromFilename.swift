import Foundation

public extension MediaInfo {
    /// Best-effort technical info parsed from a **release-style filename** —
    /// resolution / video codec / HDR / audio codec + channels — for sources
    /// that carry no probed stream metadata (SMB, #172/#213). It's only the
    /// scene tags in the name (`1080p`, `x265`, `DTS 5.1`, `HDR`…), not a real
    /// probe, but it's enough to populate Detail's inline tech line + Technical
    /// Details. Returns `nil` when nothing recognizable is present (so the tech
    /// section just stays hidden rather than showing an empty card).
    static func fromFilename(_ filename: String, container: String? = nil) -> MediaInfo? {
        // Space-pad + lowercase + `_`→space so word-boundary `contains` works;
        // keep a dot copy for channel layouts like `5.1`.
        let padded = " " + filename.lowercased().replacingOccurrences(of: "_", with: " ") + " "
        let raw = filename.lowercased()
        func has(_ needle: String) -> Bool { padded.contains(needle) }

        let resolution: String?
        if has("2160p") || has("4k") || has(" uhd ") { resolution = "4K" }
        else if has("1080p") { resolution = "1080p" }
        else if has("720p") { resolution = "720p" }
        else if has("480p") { resolution = "480p" }
        else { resolution = nil }

        let videoCodec: String?
        if has("x265") || has("h265") || has("h 265") || has("hevc") { videoCodec = "HEVC" }
        else if has("x264") || has("h264") || has("h 264") || has(" avc ") { videoCodec = "H.264" }
        else { videoCodec = nil }

        let isDolbyVision = has("dolby vision") || has(" dovi ") || has(" dv ") || raw.contains(".dv.")
        let isHDR = has(" hdr ") || has("hdr10") || isDolbyVision

        let audioCodec: String?
        if has("truehd") || has("atmos") { audioCodec = "TrueHD" }
        else if has("dts-hd") || has("dtshd") || has("dts hd") || has("dts x") { audioCodec = "DTS-HD" }
        else if has(" dts ") { audioCodec = "DTS" }
        else if has("eac3") || has("e-ac3") || has(" ddp") || has("dd+") { audioCodec = "EAC3" }
        else if has(" ac3 ") || has(" dd ") || has("dd5") || has("dd2") { audioCodec = "AC3" }
        else if has(" aac") { audioCodec = "AAC" }
        else if has("flac") { audioCodec = "FLAC" }
        else { audioCodec = nil }

        let channels: Int?
        if raw.contains("7.1") || has(" 7 1 ") { channels = 8 }
        else if raw.contains("5.1") || has(" 5 1 ") || has("5 1 ") { channels = 6 }
        else if raw.contains("2.0") || has(" 2 0 ") || has(" stereo ") { channels = 2 }
        else { channels = nil }

        let foundAnything = resolution != nil || videoCodec != nil || audioCodec != nil
            || channels != nil || isHDR
        guard foundAnything || container != nil else { return nil }

        return MediaInfo(
            videoCodec: videoCodec,
            audioCodec: audioCodec,
            audioChannels: channels,
            videoResolution: resolution,
            isHDR: isHDR,
            isDolbyVision: isDolbyVision,
            container: container
        )
    }
}
