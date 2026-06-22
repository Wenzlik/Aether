import Foundation

/// A track resolved for fMP4 output — the muxer's normalised view of a
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
            let rate = UInt32(t.sampleRate ?? 48_000)
            self.init(
                trackID: trackID, kind: .audio, timescale: rate,   // audio media timescale = sample rate (exact AAC frame durations)
                audioCodec: codec, codecConfig: config, language: t.language,
                channels: UInt16(clamping: t.channels ?? 2),
                sampleRate: rate)
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

/// Writes a fragmented-MP4 stream from remuxed Matroska samples (#476 Tier 1):
/// an **initialization segment** (`ftyp` + `moov`) followed by **media
/// segments** (`moof` + `mdat`). Codec samples pass through unchanged — MKV
/// already stores H.264/HEVC as length-prefixed NALs (matching avcC) and AAC as
/// raw frames — so this only assembles the box structure, no transcoding.
struct FragmentedMP4Writer {
    let tracks: [RemuxTrack]
    /// Total movie duration in the movie timescale (1000). Declared in `mehd` so
    /// AVPlayer knows the full length up front — without it, a fragmented stream
    /// served over the resource loader shows a wrong/short duration (it can only
    /// guess from the fragments seen so far). 0 = unknown (omit `mehd`).
    let movieDurationTicks: UInt32

    init(tracks: [RemuxTrack], movieDurationTicks: UInt32 = 0) {
        self.tracks = tracks
        self.movieDurationTicks = movieDurationTicks
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
        w.u32(movieDurationTicks)   // total duration (VOD; 0 would signal "live")
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
        w.u32(movieDurationTicks)   // total duration (movie timescale)
        w.u32(0); w.u32(0)       // reserved
        w.u16(0)                 // layer
        // alternate_group puts tracks of the same media type into a selectable
        // set — without it, AVFoundation builds no media-selection group and the
        // player's audio/subtitle menu is empty. 0 = video, 1 = audio, 2 = subtitle.
        let alternateGroup: UInt16
        switch track.kind {
        case .video:    alternateGroup = 0
        case .audio:    alternateGroup = 1
        case .subtitle: alternateGroup = 2
        }
        w.u16(alternateGroup)
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
        // Total duration in this track's timescale (movie ticks → track ticks).
        w.u32(UInt32(clamping: Int(movieDurationTicks) * Int(track.timescale) / 1000))
        w.u16(packedLanguage(track.language))
        w.u16(0)                 // pre_defined
        return MP4Box.fullBox("mdhd", version: 0, flags: 0, w.bytes)
    }

    private func hdlr(_ track: RemuxTrack) -> [UInt8] {
        let handlerType: String
        switch track.kind {
        case .video:    handlerType = "vide"
        case .audio:    handlerType = "soun"
        case .subtitle: handlerType = "text"   // WebVTT in ISOBMFF (ISO 14496-30)
        }
        var w = MP4ByteWriter()
        w.u32(0)                 // pre_defined
        w.fourCC(handlerType)
        w.u32(0); w.u32(0); w.u32(0)  // reserved
        w.append(Array("Aether\u{0}".utf8))  // handler name, null-terminated
        return MP4Box.fullBox("hdlr", version: 0, flags: 0, w.bytes)
    }

    private func minf(_ track: RemuxTrack) -> [UInt8] {
        let header: [UInt8]
        switch track.kind {
        case .video:    header = vmhd()
        case .audio:    header = smhd()
        case .subtitle: header = nmhd()   // WebVTT tracks use a null media header
        }
        return MP4Box.container("minf", [header, dinf(), stbl(track)])
    }

    /// NullMediaHeaderBox — the media header for a WebVTT ('text' handler) track.
    private func nmhd() -> [UInt8] {
        MP4Box.fullBox("nmhd", version: 0, flags: 0, [])
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
        case .video:    return visualSampleEntry(track)
        case .audio:    return audioSampleEntry(track)
        case .subtitle: return webVTTSampleEntry()
        }
    }

    /// WebVTTSampleEntry ('wvtt', ISO 14496-30 §7.3): the SampleEntry base
    /// (6 reserved + data_reference_index) followed by a `vttC`
    /// WebVTTConfigurationBox holding the cue-less WebVTT header ("WEBVTT").
    private func webVTTSampleEntry() -> [UInt8] {
        var w = MP4ByteWriter()
        for _ in 0..<6 { w.u8(0) }                 // reserved
        w.u16(1)                                    // data_reference_index
        w.append(MP4Box.box("vttC", Array("WEBVTT".utf8)))
        return MP4Box.box("wvtt", w.bytes)
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
        w.append(esds(asc: track.codecConfig, esID: UInt16(truncatingIfNeeded: track.trackID)))
        return MP4Box.box("mp4a", w.bytes)
    }

    /// `esds` carrying the AAC AudioSpecificConfig. Mirrors the form AVFoundation
    /// emits (and expects for its media-selection grouping): the canonical 4-byte
    /// descriptor length encoding (`80 80 80 NN`) and a non-zero ES_ID. A minimal
    /// single-byte-length esds still *decodes*, but AVFoundation wouldn't expose
    /// the track as a selectable audible group.
    private func esds(asc: [UInt8], esID: UInt16) -> [UInt8] {
        func descriptor(_ tag: UInt8, _ payload: [UInt8]) -> [UInt8] {
            [tag, 0x80, 0x80, 0x80, UInt8(payload.count)] + payload
        }
        let dsi = descriptor(0x05, asc)                                    // DecoderSpecificInfo
        // DecoderConfigDescriptor: objType 0x40 (AAC), streamType 0x15 (audio),
        // bufferSizeDB(3) + maxBitrate(4) + avgBitrate(4), then the DSI.
        let dcd = descriptor(0x04, [0x40, 0x15] + [UInt8](repeating: 0, count: 11) + dsi)
        let sl = descriptor(0x06, [0x02])                                  // SLConfigDescriptor
        // ES_Descriptor: ES_ID (2) + flags (1), then the config + SL descriptors.
        let es = descriptor(0x03, [UInt8(esID >> 8), UInt8(esID & 0xFF), 0x00] + dcd + sl)
        return MP4Box.fullBox("esds", version: 0, flags: 0, es)
    }

    private func mvex() -> [UInt8] {
        var children: [[UInt8]] = []
        if movieDurationTicks > 0 {
            var w = MP4ByteWriter(); w.u32(movieDurationTicks)   // fragment_duration (movie timescale)
            children.append(MP4Box.fullBox("mehd", version: 0, flags: 0, w.bytes))
        }
        children += tracks.map { trex($0) }
        return MP4Box.container("mvex", children)
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

    // MARK: - Media segments (moof + mdat)

    /// One sample (frame) in a fragment.
    struct Sample: Sendable, Equatable {
        let data: [UInt8]
        /// DTS-timeline duration (next DTS − this DTS), in track timescale ticks.
        let duration: UInt32
        let isKeyframe: Bool
        /// Composition offset = PTS − DTS, for B-frame reordering. Signed
        /// (trun version 1). 0 for streams with no reordering.
        let compositionOffset: Int32
    }

    /// One track's samples within a fragment, plus the decode time of its first
    /// sample (`tfdt` base).
    struct FragmentTrack: Sendable {
        let trackID: UInt32
        let baseDecodeTime: UInt64
        let samples: [Sample]
    }

    /// A media segment: `moof` + `mdat`. `data_offset` in each `trun` is relative
    /// to the `moof` start (default-base-is-moof), so it depends on the moof's
    /// own size — built in two passes (the size is independent of the offset
    /// *values*, only the structure, so pass 1 measures and pass 2 fills).
    func mediaSegment(sequenceNumber: UInt32, tracks: [FragmentTrack]) -> [UInt8] {
        let trackDataSizes = tracks.map { $0.samples.reduce(0) { $0 + $1.data.count } }
        let moofSize = moof(sequenceNumber: sequenceNumber, tracks: tracks,
                            dataOffsets: Array(repeating: 0, count: tracks.count)).count

        var offsets: [Int] = []
        var cumulative = 0
        for size in trackDataSizes {
            offsets.append(moofSize + 8 + cumulative)   // +8 for the mdat header
            cumulative += size
        }

        let realMoof = moof(sequenceNumber: sequenceNumber, tracks: tracks, dataOffsets: offsets)
        var mdat: [UInt8] = []
        for track in tracks { for sample in track.samples { mdat += sample.data } }
        return realMoof + MP4Box.box("mdat", mdat)
    }

    /// The exact byte size `mediaSegment` produces for the given per-track
    /// (sampleCount, total sample-data bytes) — without materialising the
    /// segment. Lets the stream index be built from frame *sizes* alone, so it
    /// never reads/copies the gigabytes of sample data. **Must stay in lockstep
    /// with `mediaSegment` / `moof` / `traf` / `trun`** (a test asserts equality).
    ///
    /// moof = box(8) + mfhd(16) + Σ traf; traf = box(8)+tfhd(16)+tfdt(20)+trun;
    /// trun = box(8)+vf(4)+count(4)+dataOffset(4)+16·samples. mdat = box(8)+data.
    func mediaSegmentByteSize(_ tracks: [(sampleCount: Int, dataBytes: Int)]) -> Int {
        var size = 8 + 16 + 8   // moof header + mfhd + mdat header
        for track in tracks {
            size += 64 + 16 * track.sampleCount   // one traf (64 fixed + 16/sample in trun)
            size += track.dataBytes               // this track's mdat payload
        }
        return size
    }

    private func moof(sequenceNumber: UInt32, tracks: [FragmentTrack], dataOffsets: [Int]) -> [UInt8] {
        var mfhd = MP4ByteWriter(); mfhd.u32(sequenceNumber)
        var children: [[UInt8]] = [MP4Box.fullBox("mfhd", version: 0, flags: 0, mfhd.bytes)]
        for (index, track) in tracks.enumerated() {
            children.append(traf(track, dataOffset: dataOffsets[index]))
        }
        return MP4Box.container("moof", children)
    }

    private func traf(_ track: FragmentTrack, dataOffset: Int) -> [UInt8] {
        var tfhd = MP4ByteWriter(); tfhd.u32(track.trackID)
        // flags 0x020000 = default-base-is-moof (data offsets relative to moof).
        let tfhdBox = MP4Box.fullBox("tfhd", version: 0, flags: 0x02_0000, tfhd.bytes)

        var tfdt = MP4ByteWriter(); tfdt.u64(track.baseDecodeTime)
        let tfdtBox = MP4Box.fullBox("tfdt", version: 1, flags: 0, tfdt.bytes)

        return MP4Box.container("traf", [tfhdBox, tfdtBox, trun(track.samples, dataOffset: dataOffset)])
    }

    private func trun(_ samples: [Sample], dataOffset: Int) -> [UInt8] {
        var w = MP4ByteWriter()
        w.u32(UInt32(samples.count))
        w.i32(Int32(dataOffset))
        for sample in samples {
            w.u32(sample.duration)
            w.u32(UInt32(sample.data.count))
            // sync sample → sample_depends_on=2; otherwise sample_is_non_sync_sample.
            w.u32(sample.isKeyframe ? 0x0200_0000 : 0x0001_0000)
            w.i32(sample.compositionOffset)   // PTS − DTS (B-frame reordering)
        }
        // flags: data-offset(0x1) | sample-duration(0x100) | sample-size(0x200)
        // | sample-flags(0x400) | sample-composition-time-offset(0x800). Version 1
        // makes the composition offset signed.
        return MP4Box.fullBox("trun", version: 1, flags: 0x00_0F01, w.bytes)
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
