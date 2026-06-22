import Foundation

/// Normalised codec identities for playback routing (#476). The remux shim
/// (Tier 1) only ever helps containers wrapping codecs **AVFoundation already
/// decodes** — so the routing decision turns on "what codec is this", separate
/// from "what container". Both Matroska `CodecID` strings (from the demuxer
/// probe) and generic codec labels (from Plex/Jellyfin `MediaInfo`) normalise
/// into these.

public enum VideoCodec: Sendable, Equatable {
    case h264
    case hevc
    case other(String)

    /// Whether AVFoundation can decode this video codec (and therefore whether a
    /// remux-to-fMP4 is enough — no re-encode). H.264/HEVC: yes. MPEG-4 ASP
    /// (DivX/Xvid), VC-1, VP9, AV1, MPEG-2 in MKV: no — those need Tier 2/3.
    public var isAVFoundationDecodable: Bool {
        switch self {
        case .h264, .hevc: return true
        case .other:       return false
        }
    }

    /// Whether the remux muxer can build a sample entry for this codec today.
    /// For video this matches `isAVFoundationDecodable` (avc1/hvc1 from the
    /// container's avcC/hvcC).
    public var isRemuxPackageable: Bool { isAVFoundationDecodable }

    /// Map a Matroska `CodecID` (e.g. `"V_MPEG4/ISO/AVC"`) to a codec identity.
    public init(matroskaCodecID id: String) {
        switch id {
        case "V_MPEG4/ISO/AVC": self = .h264
        case "V_MPEGH/ISO/HEVC": self = .hevc
        default: self = .other(id)
        }
    }

    /// Map a generic codec label (e.g. Plex `"h264"`, `"hevc"`/`"h265"`).
    public init(label: String) {
        switch label.lowercased() {
        case "h264", "avc": self = .h264
        case "hevc", "h265": self = .hevc
        default: self = .other(label)
        }
    }
}

public enum AudioCodec: Sendable, Equatable {
    case aac
    case ac3
    case eac3
    case mp3
    case alac
    case pcm
    case other(String)

    /// Whether AVFoundation can decode this audio codec. AAC/ALAC/MP3/PCM: yes.
    /// AC-3 / E-AC-3: yes on Apple hardware, but passthrough/decode is
    /// **device-dependent** (#476 flags verifying on real hardware) — included
    /// here as decodable; the muxer/playback path is where a real-device check
    /// would gate them if needed. DTS / TrueHD: no — Tier 2/3.
    public var isAVFoundationDecodable: Bool {
        switch self {
        case .aac, .ac3, .eac3, .mp3, .alac, .pcm: return true
        case .other: return false
        }
    }

    /// Whether the remux muxer can build a sample entry for this codec **today**.
    /// Only AAC (`mp4a`/`esds` from the AudioSpecificConfig) is implemented.
    /// AC-3 / E-AC-3 are AVFoundation-decodable but need `ac-3`/`ec-3` sample
    /// entries whose `dac3`/`dec3` boxes must be synthesised from the bitstream
    /// (MKV carries no CodecPrivate for them) — until then a title with non-AAC
    /// audio routes to a fallback engine rather than remuxing to silent video.
    public var isRemuxPackageable: Bool {
        self == .aac
    }

    /// Map a Matroska `CodecID` (e.g. `"A_AAC"`, `"A_AC3"`, `"A_DTS"`).
    public init(matroskaCodecID id: String) {
        // Matroska AAC ids can be `A_AAC` or `A_AAC/MPEG4/LC` etc.
        if id == "A_AAC" || id.hasPrefix("A_AAC/") { self = .aac; return }
        if id.hasPrefix("A_PCM/") { self = .pcm; return }
        switch id {
        case "A_AC3": self = .ac3
        case "A_EAC3": self = .eac3
        case "A_MPEG/L3": self = .mp3
        case "A_ALAC": self = .alac
        default: self = .other(id)
        }
    }

    /// Map a generic codec label (e.g. Plex `"aac"`, `"ac3"`, `"dts"`).
    public init(label: String) {
        switch label.lowercased() {
        case "aac": self = .aac
        case "ac3": self = .ac3
        case "eac3", "e-ac-3", "ec-3": self = .eac3
        case "mp3": self = .mp3
        case "alac": self = .alac
        case "pcm": self = .pcm
        default: self = .other(label)
        }
    }
}
