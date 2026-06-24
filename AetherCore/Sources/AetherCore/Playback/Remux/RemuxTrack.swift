import Foundation

/// A track resolved for MP4 output — the muxer's normalised view of a
/// `MatroskaTrack` (#476 Tier 1). Carries the codec config (avcC / hvcC /
/// AudioSpecificConfig) and the geometry each sample-entry box needs.
public struct RemuxTrack: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case video, audio, subtitle }

    /// 1-based fMP4 track id (also the moof track id).
    public let trackID: UInt32
    public let kind: Kind
    /// Ticks per second for this track's timeline (sample timestamps are in
    /// these units). Derived from the Matroska timestamp scale.
    public let timescale: UInt32
    public let videoCodec: VideoCodec?
    public let audioCodec: AudioCodec?
    /// avcC / hvcC for video, AudioSpecificConfig for AAC.
    public let codecConfig: [UInt8]
    public let language: String?

    // Video geometry.
    public let width: UInt16
    public let height: UInt16
    // Audio geometry.
    public let channels: UInt16
    public let sampleRate: UInt32
    /// Audio-media-timescale duration of one coded frame: AAC-LC = 1024,
    /// AC-3 = 1536, E-AC-3 = `numblks * 256`. Drives the sample-table spacing so
    /// audio stays in sync with video.
    public let audioSamplesPerFrame: UInt32

    public init(
        trackID: UInt32,
        kind: Kind,
        timescale: UInt32,
        videoCodec: VideoCodec? = nil,
        audioCodec: AudioCodec? = nil,
        codecConfig: [UInt8],
        language: String? = nil,
        width: UInt16 = 0,
        height: UInt16 = 0,
        channels: UInt16 = 0,
        sampleRate: UInt32 = 0,
        audioSamplesPerFrame: UInt32 = 1024
    ) {
        self.trackID = trackID
        self.kind = kind
        self.timescale = timescale
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.codecConfig = codecConfig
        self.language = language
        self.width = width
        self.height = height
        self.channels = channels
        self.sampleRate = sampleRate
        self.audioSamplesPerFrame = audioSamplesPerFrame
    }

    /// A copy of this audio track with the synthesised (E-)AC-3 `dac3`/`dec3`
    /// config and exact bitstream-derived geometry filled in. The media
    /// timescale follows the sample rate (exact per-frame durations).
    public func settingAudioConfig(_ config: [UInt8], channels: UInt16,
                                   sampleRate: UInt32, samplesPerFrame: UInt32) -> RemuxTrack {
        RemuxTrack(
            trackID: trackID, kind: kind, timescale: sampleRate,
            videoCodec: videoCodec, audioCodec: audioCodec, codecConfig: config,
            language: language, width: width, height: height,
            channels: channels, sampleRate: sampleRate, audioSamplesPerFrame: samplesPerFrame)
    }

    /// Build from a probed Matroska track. Returns `nil` for tracks the muxer
    /// can't package yet (non-AAC audio, non-H.264/HEVC video, missing config) —
    /// the caller then declines the remux and falls back.
    public init?(matroska t: MatroskaTrack, trackID: UInt32, timescaleTicksPerSecond: UInt32) {
        switch t.type {
        case .video:
            let codec = VideoCodec(matroskaCodecID: t.codecID)
            guard codec.isAVFoundationDecodable, let config = t.codecPrivate, !config.isEmpty else { return nil }
            self.init(
                trackID: trackID, kind: .video, timescale: timescaleTicksPerSecond,
                videoCodec: codec, codecConfig: config, language: t.language,
                width: UInt16(clamping: t.pixelWidth ?? 0), height: UInt16(clamping: t.pixelHeight ?? 0))
        case .audio:
            let codec = AudioCodec(matroskaCodecID: t.codecID)
            let rate = UInt32(t.sampleRate ?? 48_000)
            switch codec {
            case .aac:
                // AAC carries its AudioSpecificConfig as CodecPrivate.
                guard let config = t.codecPrivate, !config.isEmpty else { return nil }
                self.init(
                    trackID: trackID, kind: .audio, timescale: rate,   // audio media timescale = sample rate (exact AAC frame durations)
                    audioCodec: codec, codecConfig: config, language: t.language,
                    channels: UInt16(clamping: t.channels ?? 2),
                    sampleRate: rate, audioSamplesPerFrame: 1024)
            case .ac3, .eac3:
                // (E-)AC-3 has no CodecPrivate; the dac3/dec3 config + exact
                // geometry are synthesised from the first frame by the remuxer
                // (AudioBitstreamConfig). Carry MKV hints for now; an empty
                // codecConfig signals "needs synthesis".
                self.init(
                    trackID: trackID, kind: .audio, timescale: rate,
                    audioCodec: codec, codecConfig: [], language: t.language,
                    channels: UInt16(clamping: t.channels ?? 2),
                    sampleRate: rate, audioSamplesPerFrame: codec == .ac3 ? 1536 : 1536)
            default:
                // DTS / TrueHD / MP3 / PCM etc. aren't packaged → bail to fallback.
                return nil
            }
        case .subtitle:
            // Only S_TEXT/UTF8 (SubRip/SRT) is carried, repackaged as WebVTT
            // (#476 P6). Image subs (PGS/VobSub) and ASS/SSA aren't supported —
            // returning nil here just drops the track; playback still works.
            guard t.codecID == "S_TEXT/UTF8" else { return nil }
            self.init(
                trackID: trackID, kind: .subtitle, timescale: timescaleTicksPerSecond,
                codecConfig: [], language: t.language)
        case .other:
            return nil
        }
    }
}
