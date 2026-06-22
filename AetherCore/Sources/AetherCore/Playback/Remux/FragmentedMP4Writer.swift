import Foundation

/// A track resolved for fMP4 output — the muxer's normalised view of a
/// `MatroskaTrack` (#476 Tier 1). Carries the codec config (avcC / hvcC /
/// AudioSpecificConfig) and the geometry each sample-entry box needs.
public struct RemuxTrack: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case video, audio }

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
        sampleRate: UInt32 = 0
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
            // Only AAC (with its AudioSpecificConfig) is packageable today.
            guard codec == .aac, let config = t.codecPrivate, !config.isEmpty else { return nil }
            self.init(
                trackID: trackID, kind: .audio, timescale: timescaleTicksPerSecond,
                audioCodec: codec, codecConfig: config, language: t.language,
                channels: UInt16(clamping: t.channels ?? 2),
                sampleRate: UInt32(t.sampleRate ?? 48_000))
        case .subtitle, .other:
            return nil
        }
    }
}

/// Writes a fragmented-MP4 stream from remuxed Matroska samples (#476 Tier 1):
/// an **initialization segment** (`ftyp` + `moov`) followed by **media
/// segments** (`moof` + `mdat`). Codec samples pass through unchanged — MKV
/// already stores H.264/HEVC as length-prefixed NALs (matching avcC) and AAC as
/// raw frames — so this only assembles the box structure, no transcoding.
struct FragmentedMP4Writer {
    let tracks: [RemuxTrack]

    init(tracks: [RemuxTrack]) {
        self.tracks = tracks
    }

    // MARK: - Initialization segment

    func initializationSegment() -> [UInt8] {
        MP4Box.ftyp() + moov()
    }

    private func moov() -> [UInt8] {
        var children: [[UInt8]] = [mvhd()]
        children += tracks.map { trak($0) }
        children.append(mvex())
        return MP4Box.container("moov", children)
    }

    private func mvhd() -> [UInt8] {
        var w = MP4ByteWriter()
        w.u32(0)                 // creation_time
        w.u32(0)                 // modification_time
        w.u32(1000)              // timescale (movie)
        w.u32(0)                 // duration (0 = unknown / fragmented)
        w.u32(0x0001_0000)       // rate 1.0
        w.u16(0x0100)            // volume 1.0
        w.u16(0)                 // reserved
        w.u32(0); w.u32(0)       // reserved
        appendIdentityMatrix(&w)
        for _ in 0..<6 { w.u32(0) }   // pre_defined
        w.u32(UInt32(tracks.count) + 1)  // next_track_ID
        return MP4Box.fullBox("mvhd", version: 0, flags: 0, w.bytes)
    }

    private func trak(_ track: RemuxTrack) -> [UInt8] {
        MP4Box.container("trak", [tkhd(track), mdia(track)])
    }

    private func tkhd(_ track: RemuxTrack) -> [UInt8] {
        var w = MP4ByteWriter()
        w.u32(0); w.u32(0)       // creation / modification
        w.u32(track.trackID)
        w.u32(0)                 // reserved
        w.u32(0)                 // duration
        w.u32(0); w.u32(0)       // reserved
        w.u16(0)                 // layer
        w.u16(0)                 // alternate_group
        w.u16(track.kind == .audio ? 0x0100 : 0)  // volume
        w.u16(0)                 // reserved
        appendIdentityMatrix(&w)
        w.u32(UInt32(track.width) << 16)   // width 16.16
        w.u32(UInt32(track.height) << 16)  // height 16.16
        // flags 0x07 = track_enabled | in_movie | in_preview
        return MP4Box.fullBox("tkhd", version: 0, flags: 0x0000_07, w.bytes)
    }

    private func mdia(_ track: RemuxTrack) -> [UInt8] {
        MP4Box.container("mdia", [mdhd(track), hdlr(track), minf(track)])
    }

    private func mdhd(_ track: RemuxTrack) -> [UInt8] {
        var w = MP4ByteWriter()
        w.u32(0); w.u32(0)       // creation / modification
        w.u32(track.timescale)
        w.u32(0)                 // duration
        w.u16(packedLanguage(track.language))
        w.u16(0)                 // pre_defined
        return MP4Box.fullBox("mdhd", version: 0, flags: 0, w.bytes)
    }

    private func hdlr(_ track: RemuxTrack) -> [UInt8] {
        var w = MP4ByteWriter()
        w.u32(0)                 // pre_defined
        w.fourCC(track.kind == .video ? "vide" : "soun")
        w.u32(0); w.u32(0); w.u32(0)  // reserved
        w.append(Array("Aether\u{0}".utf8))  // handler name, null-terminated
        return MP4Box.fullBox("hdlr", version: 0, flags: 0, w.bytes)
    }

    private func minf(_ track: RemuxTrack) -> [UInt8] {
        let header = track.kind == .video ? vmhd() : smhd()
        return MP4Box.container("minf", [header, dinf(), stbl(track)])
    }

    private func vmhd() -> [UInt8] {
        var w = MP4ByteWriter()
        w.u16(0)                 // graphicsmode
        w.u16(0); w.u16(0); w.u16(0)  // opcolor
        return MP4Box.fullBox("vmhd", version: 0, flags: 1, w.bytes)
    }

    private func smhd() -> [UInt8] {
        var w = MP4ByteWriter()
        w.u16(0)                 // balance
        w.u16(0)                 // reserved
        return MP4Box.fullBox("smhd", version: 0, flags: 0, w.bytes)
    }

    private func dinf() -> [UInt8] {
        // dref with a single self-contained url entry (flags 0x01).
        let url = MP4Box.fullBox("url ", version: 0, flags: 0x0000_01, [])
        var dref = MP4ByteWriter()
        dref.u32(1)              // entry_count
        dref.append(url)
        return MP4Box.container("dinf", [MP4Box.fullBox("dref", version: 0, flags: 0, dref.bytes)])
    }

    private func stbl(_ track: RemuxTrack) -> [UInt8] {
        let empty32 = MP4Box.fullBox("stts", version: 0, flags: 0, [0, 0, 0, 0])
        let stsc = MP4Box.fullBox("stsc", version: 0, flags: 0, [0, 0, 0, 0])
        var stsz = MP4ByteWriter(); stsz.u32(0); stsz.u32(0)  // sample_size, sample_count
        let stco = MP4Box.fullBox("stco", version: 0, flags: 0, [0, 0, 0, 0])
        return MP4Box.container("stbl", [
            stsd(track),
            empty32,
            stsc,
            MP4Box.fullBox("stsz", version: 0, flags: 0, stsz.bytes),
            stco
        ])
    }

    private func stsd(_ track: RemuxTrack) -> [UInt8] {
        var w = MP4ByteWriter()
        w.u32(1)                 // entry_count
        w.append(sampleEntry(track))
        return MP4Box.fullBox("stsd", version: 0, flags: 0, w.bytes)
    }

    private func sampleEntry(_ track: RemuxTrack) -> [UInt8] {
        switch track.kind {
        case .video: return visualSampleEntry(track)
        case .audio: return audioSampleEntry(track)
        }
    }

    private func visualSampleEntry(_ track: RemuxTrack) -> [UInt8] {
        let type = track.videoCodec == .hevc ? "hvc1" : "avc1"
        let configType = track.videoCodec == .hevc ? "hvcC" : "avcC"
        var w = MP4ByteWriter()
        for _ in 0..<6 { w.u8(0) }      // reserved
        w.u16(1)                         // data_reference_index
        w.u16(0); w.u16(0)               // pre_defined, reserved
        w.u32(0); w.u32(0); w.u32(0)     // pre_defined
        w.u16(track.width)
        w.u16(track.height)
        w.u32(0x0048_0000)               // horizresolution 72dpi
        w.u32(0x0048_0000)               // vertresolution 72dpi
        w.u32(0)                         // reserved
        w.u16(1)                         // frame_count
        for _ in 0..<32 { w.u8(0) }      // compressorname (32 bytes)
        w.u16(0x0018)                    // depth
        w.i16(-1)                        // pre_defined
        w.append(MP4Box.box(configType, track.codecConfig))  // avcC / hvcC
        return MP4Box.box(type, w.bytes)
    }

    private func audioSampleEntry(_ track: RemuxTrack) -> [UInt8] {
        var w = MP4ByteWriter()
        for _ in 0..<6 { w.u8(0) }      // reserved
        w.u16(1)                         // data_reference_index
        w.u32(0); w.u32(0)               // reserved
        w.u16(track.channels)
        w.u16(16)                        // samplesize
        w.u16(0)                         // pre_defined
        w.u16(0)                         // reserved
        w.u32(track.sampleRate << 16)    // samplerate 16.16
        w.append(esds(asc: track.codecConfig))
        return MP4Box.box("mp4a", w.bytes)
    }

    /// Minimal `esds` carrying the AAC AudioSpecificConfig (configs are < 128
    /// bytes, so single-byte descriptor lengths suffice).
    private func esds(asc: [UInt8]) -> [UInt8] {
        let dsi: [UInt8] = [0x05, UInt8(asc.count)] + asc                  // DecoderSpecificInfo
        // DecoderConfigDescriptor: objType 0x40 (AAC), streamType 0x15 (audio),
        // bufferSizeDB(3) + maxBitrate(4) + avgBitrate(4) all zero, then dsi.
        let dcdPayload: [UInt8] = [0x40, 0x15] + [UInt8](repeating: 0, count: 11) + dsi
        let dcd: [UInt8] = [0x04, UInt8(dcdPayload.count)] + dcdPayload
        let sl: [UInt8] = [0x06, 0x01, 0x02]                               // SLConfigDescriptor
        let esPayload: [UInt8] = [0x00, 0x00, 0x00] + dcd + sl             // ES_ID(2) + flags(1)
        let es: [UInt8] = [0x03, UInt8(esPayload.count)] + esPayload
        return MP4Box.fullBox("esds", version: 0, flags: 0, es)
    }

    private func mvex() -> [UInt8] {
        MP4Box.container("mvex", tracks.map { trex($0) })
    }

    private func trex(_ track: RemuxTrack) -> [UInt8] {
        var w = MP4ByteWriter()
        w.u32(track.trackID)
        w.u32(1)                 // default_sample_description_index
        w.u32(0)                 // default_sample_duration
        w.u32(0)                 // default_sample_size
        w.u32(0)                 // default_sample_flags
        return MP4Box.fullBox("trex", version: 0, flags: 0, w.bytes)
    }

    // MARK: - Helpers

    private func appendIdentityMatrix(_ w: inout MP4ByteWriter) {
        let m: [UInt32] = [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000]
        for v in m { w.u32(v) }
    }

    /// Pack an ISO-639-2/T language into the 15-bit mdhd form (each letter as
    /// `letter - 0x60`, 5 bits). Unknown → `"und"`.
    private func packedLanguage(_ code: String?) -> UInt16 {
        let lang = (code?.count == 3 ? code! : "und").lowercased()
        let letters = Array(lang.utf8)
        let a = UInt16(letters[0]) - 0x60
        let b = UInt16(letters[1]) - 0x60
        let c = UInt16(letters[2]) - 0x60
        return (a << 10) | (b << 5) | c
    }
}
