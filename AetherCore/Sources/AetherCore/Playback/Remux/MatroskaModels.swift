import Foundation

/// Track kind, per the Matroska `TrackType` element. Only the cases Aether's
/// remux shim reasons about are named; others fall through to `.other`.
public enum MatroskaTrackType: Int, Sendable, Equatable {
    case video = 1
    case audio = 2
    case subtitle = 17
    case other = 0

    init(rawTrackType: UInt64) {
        self = MatroskaTrackType(rawValue: Int(rawTrackType)) ?? .other
    }
}

/// One track parsed from a Matroska `TrackEntry`. Carries everything the remux
/// muxer needs to build an fMP4 sample-description for the track: the codec id,
/// the codec-private config blob (avcC / hvcC / AudioSpecificConfig), and the
/// video/audio geometry. The probe stage (`MatroskaDemuxer.probe`) fills these;
/// `RemuxEngine.canPlay` reads `codecID` to decide whether AVFoundation can
/// decode the elementary stream.
public struct MatroskaTrack: Sendable, Equatable {
    public let number: UInt64
    public let type: MatroskaTrackType
    /// Matroska codec id, e.g. `"V_MPEG4/ISO/AVC"`, `"V_MPEGH/ISO/HEVC"`,
    /// `"A_AAC"`, `"A_AC3"`, `"S_TEXT/UTF8"`.
    public let codecID: String
    /// `CodecPrivate` — the decoder config bytes. For H.264 this is the avcC
    /// box, for HEVC the hvcC box, for AAC the AudioSpecificConfig. Required to
    /// build the fMP4 sample entry; `nil` for codecs that don't carry one.
    public let codecPrivate: [UInt8]?
    public let language: String?
    public let name: String?
    public let isDefault: Bool
    public let isForced: Bool
    /// Nanoseconds per frame, when the container states it (`DefaultDuration`).
    public let defaultDurationNs: UInt64?

    // Video geometry (nil for non-video tracks).
    public let pixelWidth: UInt64?
    public let pixelHeight: UInt64?

    // Audio geometry (nil for non-audio tracks).
    public let channels: UInt64?
    public let sampleRate: Double?
    public let bitDepth: UInt64?

    public init(
        number: UInt64,
        type: MatroskaTrackType,
        codecID: String,
        codecPrivate: [UInt8]? = nil,
        language: String? = nil,
        name: String? = nil,
        isDefault: Bool = false,
        isForced: Bool = false,
        defaultDurationNs: UInt64? = nil,
        pixelWidth: UInt64? = nil,
        pixelHeight: UInt64? = nil,
        channels: UInt64? = nil,
        sampleRate: Double? = nil,
        bitDepth: UInt64? = nil
    ) {
        self.number = number
        self.type = type
        self.codecID = codecID
        self.codecPrivate = codecPrivate
        self.language = language
        self.name = name
        self.isDefault = isDefault
        self.isForced = isForced
        self.defaultDurationNs = defaultDurationNs
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.channels = channels
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
    }
}

/// Segment-level timing from the Matroska `Info` element.
public struct MatroskaInfo: Sendable, Equatable {
    /// Nanoseconds per timestamp tick. Block timestamps are in these units;
    /// Matroska's default is 1,000,000 ns (1 ms).
    public let timestampScaleNs: UInt64
    /// Total duration in timestamp-scale ticks, when stated.
    public let durationTicks: Double?

    public init(timestampScaleNs: UInt64 = 1_000_000, durationTicks: Double? = nil) {
        self.timestampScaleNs = timestampScaleNs
        self.durationTicks = durationTicks
    }

    /// Duration in seconds, if the container stated it.
    public var durationSeconds: Double? {
        durationTicks.map { $0 * Double(timestampScaleNs) / 1_000_000_000 }
    }
}

/// One coded frame (sample) extracted from a cluster's `SimpleBlock` / `Block`.
/// The remux muxer repackages these into fMP4 samples — so this carries exactly
/// what a sample needs: which track, when, whether it's a sync sample, and the
/// raw coded bytes (still in the container's bitstream form — e.g. H.264 NALs in
/// Annex-B; the muxer converts to AVCC).
public struct MatroskaFrame: Sendable, Equatable {
    public let trackNumber: UInt64
    /// Absolute presentation timestamp in timestamp-scale ticks (cluster
    /// timestamp + the block's signed relative offset).
    public let timestampTicks: Int64
    public let isKeyframe: Bool
    public let data: [UInt8]

    public init(trackNumber: UInt64, timestampTicks: Int64, isKeyframe: Bool, data: [UInt8]) {
        self.trackNumber = trackNumber
        self.timestampTicks = timestampTicks
        self.isKeyframe = isKeyframe
        self.data = data
    }
}

/// The result of probing a Matroska file's head: timing + track list, plus the
/// byte offset where cluster (frame) data begins — the entry point the frame
/// reader uses in a later stage.
public struct MatroskaSegmentInfo: Sendable, Equatable {
    public let info: MatroskaInfo
    public let tracks: [MatroskaTrack]
    /// File offset of the first `Cluster` element (or `nil` if the probe hit
    /// EOF before any cluster). The frame reader resumes from here.
    public let firstClusterOffset: Int?

    public var videoTracks: [MatroskaTrack] { tracks.filter { $0.type == .video } }
    public var audioTracks: [MatroskaTrack] { tracks.filter { $0.type == .audio } }
}
