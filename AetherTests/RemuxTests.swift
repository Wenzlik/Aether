import Testing
import Foundation
@testable import AetherCore

/// Tests for the pure-Swift MKV→fMP4 remux shim (#476, Tier 1). Starts with the
/// EBML bedrock — the vint decoding that everything else depends on.
@Suite("AetherCore — EBMLReader (#476 remux)")
struct EBMLReaderTests {

    // MARK: vint length

    @Test("vint length from the leading byte's marker position")
    func vintLength() {
        #expect(EBMLReader.vintLength(firstByte: 0x80) == 1)   // 1000_0000
        #expect(EBMLReader.vintLength(firstByte: 0xFF) == 1)
        #expect(EBMLReader.vintLength(firstByte: 0x40) == 2)   // 0100_0000
        #expect(EBMLReader.vintLength(firstByte: 0x20) == 3)
        #expect(EBMLReader.vintLength(firstByte: 0x1A) == 4)   // 0001_1010 → 4 (EBML hdr)
        #expect(EBMLReader.vintLength(firstByte: 0x01) == 8)
        #expect(EBMLReader.vintLength(firstByte: 0x00) == nil) // invalid
    }

    // MARK: element IDs (marker kept)

    @Test("element IDs keep the marker bit (match canonical Matroska IDs)")
    func elementID() {
        // EBML header 0x1A45DFA3, Segment 0x18538067, TrackEntry 0xAE.
        var r = EBMLReader(bytes: [0x1A, 0x45, 0xDF, 0xA3, 0x18, 0x53, 0x80, 0x67, 0xAE])
        #expect(r.readElementID() == 0x1A45DFA3)
        #expect(r.readElementID() == 0x18538067)
        #expect(r.readElementID() == 0xAE)
        #expect(r.isAtEnd)
    }

    @Test("truncated ID → nil, cursor safe")
    func elementIDTruncated() {
        var r = EBMLReader(bytes: [0x1A, 0x45])   // claims 4 bytes, only 2 present
        #expect(r.readElementID() == nil)
    }

    // MARK: size vints (marker stripped)

    @Test("size vint strips the marker; multi-byte forms equal")
    func sizeVint() {
        var one = EBMLReader(bytes: [0x81])               // 1 byte → 1
        #expect(one.readSize() == .known(1))

        var oneAsTwo = EBMLReader(bytes: [0x40, 0x01])     // 2-byte encoding of 1
        #expect(oneAsTwo.readSize() == .known(1))

        var big = EBMLReader(bytes: [0x41, 0x00])          // 0x100 = 256
        #expect(big.readSize() == .known(256))
    }

    @Test("all value bits set → unknown size sentinel")
    func unknownSize() {
        var oneByte = EBMLReader(bytes: [0xFF])
        #expect(oneByte.readSize() == .unknown)
        // 8-byte unknown: 0x01 followed by seven 0xFF.
        var eightByte = EBMLReader(bytes: [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        #expect(eightByte.readSize() == .unknown)
        // Not-quite-all-ones is a concrete size, not the sentinel.
        var concrete = EBMLReader(bytes: [0x40, 0xFF])     // 255
        #expect(concrete.readSize() == .known(255))
    }

    // MARK: primitives

    @Test("big-endian unsigned / signed integer payloads")
    func integers() {
        var u = EBMLReader(bytes: [0x01, 0x00])
        #expect(u.readUInt(length: 2) == 256)

        var neg = EBMLReader(bytes: [0xFF])
        #expect(neg.readInt(length: 1) == -1)

        var pos = EBMLReader(bytes: [0x7F])
        #expect(pos.readInt(length: 1) == 127)

        var wide = EBMLReader(bytes: [0xFF, 0xFF])
        #expect(wide.readInt(length: 2) == -1)
    }

    @Test("float payloads: 4-byte Float and 8-byte Double")
    func floats() {
        // 1.0f = 0x3F800000 ; 1.0d = 0x3FF0000000000000
        var f = EBMLReader(bytes: [0x3F, 0x80, 0x00, 0x00])
        #expect(f.readFloat(length: 4) == 1.0)
        var d = EBMLReader(bytes: [0x3F, 0xF0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        #expect(d.readFloat(length: 8) == 1.0)
    }

    @Test("string payload trims trailing NUL padding")
    func strings() {
        // "V_MPEG4/ISO/AVC" is a real Matroska CodecID; pad with NULs.
        let codec = Array("matroska".utf8) + [0x00, 0x00]
        var r = EBMLReader(bytes: codec)
        #expect(r.readString(length: codec.count) == "matroska")
    }

    @Test("reads past end return nil instead of trapping")
    func boundsSafety() {
        var r = EBMLReader(bytes: [0x01])
        #expect(r.readUInt(length: 4) == nil)
        #expect(r.readBytes(length: 10) == nil)
    }
}

// MARK: - Matroska EBML builder (test fixtures)

/// Minimal EBML encoder for building synthetic `.mkv` byte fixtures in tests.
private enum MKV {
    /// Encode a length as an EBML size vint (smallest form, marker set, never
    /// the all-ones "unknown" sentinel).
    static func vint(_ n: Int) -> [UInt8] {
        var length = 1
        while UInt64(n) >= (UInt64(1) << (7 * length)) - 1 { length += 1 }
        var out = [UInt8](repeating: 0, count: length)
        var v = UInt64(n)
        var i = length - 1
        while i >= 0 { out[i] = UInt8(v & 0xFF); v >>= 8; i -= 1 }
        out[0] |= UInt8(0x80 >> (length - 1))
        return out
    }

    /// `id + size + payload`.
    static func el(_ id: [UInt8], _ payload: [UInt8]) -> [UInt8] {
        id + vint(payload.count) + payload
    }

    /// Minimal big-endian unsigned integer payload.
    static func uint(_ v: UInt64) -> [UInt8] {
        if v == 0 { return [0] }
        var bytes: [UInt8] = []
        var x = v
        while x > 0 { bytes.insert(UInt8(x & 0xFF), at: 0); x >>= 8 }
        return bytes
    }

    /// Big-endian 4-byte float payload.
    static func f32(_ v: Float) -> [UInt8] {
        withUnsafeBytes(of: v.bitPattern.bigEndian) { Array($0) }
    }

    // Canonical element IDs.
    static let ebmlHeader: [UInt8]       = [0x1A, 0x45, 0xDF, 0xA3]
    static let segment: [UInt8]          = [0x18, 0x53, 0x80, 0x67]
    static let info: [UInt8]             = [0x15, 0x49, 0xA9, 0x66]
    static let timestampScale: [UInt8]   = [0x2A, 0xD7, 0xB1]
    static let tracks: [UInt8]           = [0x16, 0x54, 0xAE, 0x6B]
    static let trackEntry: [UInt8]       = [0xAE]
    static let trackNumber: [UInt8]      = [0xD7]
    static let trackType: [UInt8]        = [0x83]
    static let codecID: [UInt8]          = [0x86]
    static let codecPrivate: [UInt8]     = [0x63, 0xA2]
    static let video: [UInt8]            = [0xE0]
    static let pixelWidth: [UInt8]       = [0xB0]
    static let pixelHeight: [UInt8]      = [0xBA]
    static let audio: [UInt8]            = [0xE1]
    static let channels: [UInt8]         = [0x9F]
    static let samplingFrequency: [UInt8] = [0xB5]
    static let cluster: [UInt8]          = [0x1F, 0x43, 0xB6, 0x75]
    static let timestamp: [UInt8]        = [0xE7]
    static let simpleBlock: [UInt8]      = [0xA3]
    static let blockGroup: [UInt8]       = [0xA0]
    static let block: [UInt8]            = [0xA1]
    static let referenceBlock: [UInt8]   = [0xFB]

    /// 2-byte big-endian signed block-relative timestamp.
    static func relTs(_ t: Int16) -> [UInt8] {
        let u = UInt16(bitPattern: t)
        return [UInt8(u >> 8), UInt8(u & 0xFF)]
    }

    /// A block payload: track vint + relative ts + flags + (optional lace) + frame bytes.
    static func blockPayload(track: Int, relTs t: Int16, flags: UInt8, lace: [UInt8] = [], frame: [UInt8]) -> [UInt8] {
        vint(track) + relTs(t) + [flags] + lace + frame
    }

    /// A synthetic MKV that is actually remuxable: a single H.264 video track
    /// with an avcC `CodecPrivate`, plus a cluster of two frames (keyframe +
    /// inter). `avcC` and frame bytes are arbitrary but distinct so tests can
    /// find them in the fMP4 output.
    static func remuxableSample(avcConfig: [UInt8], frame0: [UInt8], frame1: [UInt8]) -> Data {
        let header = el(ebmlHeader, [])
        let infoEl = el(info, el(timestampScale, uint(1_000_000)))   // 1ms ticks → timescale 1000
        let videoEntry = el(trackEntry,
            el(trackNumber, uint(1)) +
            el(trackType, uint(1)) +
            el(codecID, Array("V_MPEG4/ISO/AVC".utf8)) +
            el(codecPrivate, avcConfig) +
            el(video, el(pixelWidth, uint(640)) + el(pixelHeight, uint(360))))
        let tracksEl = el(tracks, videoEntry)
        let clusterEl = el(cluster,
            el(timestamp, uint(0)) +
            el(simpleBlock, blockPayload(track: 1, relTs: 0, flags: 0x80, frame: frame0)) +
            el(simpleBlock, blockPayload(track: 1, relTs: 40, flags: 0x00, frame: frame1)))
        let segmentEl = el(segment, infoEl + tracksEl + clusterEl)
        return Data(header + segmentEl)
    }

    /// Like `remuxableSample` but with two clusters (→ two fMP4 media segments),
    /// to exercise the streaming index across segment boundaries.
    static func remuxableTwoCluster(avcConfig: [UInt8]) -> Data {
        let header = el(ebmlHeader, [])
        let infoEl = el(info, el(timestampScale, uint(1_000_000)))
        let videoEntry = el(trackEntry,
            el(trackNumber, uint(1)) +
            el(trackType, uint(1)) +
            el(codecID, Array("V_MPEG4/ISO/AVC".utf8)) +
            el(codecPrivate, avcConfig) +
            el(video, el(pixelWidth, uint(640)) + el(pixelHeight, uint(360))))
        let tracksEl = el(tracks, videoEntry)
        func clusterAt(_ base: UInt64, _ bytes: [UInt8]) -> [UInt8] {
            el(cluster,
               el(timestamp, uint(base)) +
               el(simpleBlock, blockPayload(track: 1, relTs: 0, flags: 0x80, frame: bytes)))
        }
        let segmentEl = el(segment, infoEl + tracksEl + clusterAt(0, [0xC0, 0xC1]) + clusterAt(1000, [0xD0, 0xD1, 0xD2]))
        return Data(header + segmentEl)
    }

    /// A complete synthetic MKV: H.264 video + AAC audio, 1ms timestamp scale,
    /// followed by one (empty) cluster so the probe's cluster-stop is exercised.
    static func sample() -> Data {
        let header = el(ebmlHeader, [])
        let infoEl = el(info, el(timestampScale, uint(1_000_000)))
        let videoEntry = el(trackEntry,
            el(trackNumber, uint(1)) +
            el(trackType, uint(1)) +
            el(codecID, Array("V_MPEG4/ISO/AVC".utf8)) +
            el(video, el(pixelWidth, uint(1920)) + el(pixelHeight, uint(1080))))
        let audioEntry = el(trackEntry,
            el(trackNumber, uint(2)) +
            el(trackType, uint(2)) +
            el(codecID, Array("A_AAC".utf8)) +
            el(audio, el(channels, uint(2)) + el(samplingFrequency, f32(48_000))))
        let tracksEl = el(tracks, videoEntry + audioEntry)
        let clusterEl = el(cluster, [0x00])
        let segmentEl = el(segment, infoEl + tracksEl + clusterEl)
        return Data(header + segmentEl)
    }
}

@Suite("AetherCore — MatroskaDemuxer probe (#476 remux)")
struct MatroskaDemuxerTests {

    @Test("probes timestamp scale + both tracks with codecs and geometry")
    func probe() throws {
        let seg = try MatroskaDemuxer.probe(MKV.sample())

        #expect(seg.info.timestampScaleNs == 1_000_000)
        #expect(seg.tracks.count == 2)

        let video = try #require(seg.videoTracks.first)
        #expect(video.number == 1)
        #expect(video.type == .video)
        #expect(video.codecID == "V_MPEG4/ISO/AVC")
        #expect(video.pixelWidth == 1920)
        #expect(video.pixelHeight == 1080)

        let audio = try #require(seg.audioTracks.first)
        #expect(audio.number == 2)
        #expect(audio.type == .audio)
        #expect(audio.codecID == "A_AAC")
        #expect(audio.channels == 2)
        #expect(audio.sampleRate == 48_000)
    }

    @Test("firstClusterOffset points at the cluster element header")
    func clusterOffset() throws {
        let data = MKV.sample()
        let seg = try MatroskaDemuxer.probe(data)
        let offset = try #require(seg.firstClusterOffset)
        // Seeking there and reading an element id yields the Cluster id.
        var reader = EBMLReader(data, offset: offset)
        #expect(reader.readElementID() == 0x1F43B675)
    }

    @Test("non-Matroska bytes throw notMatroska, not a trap")
    func rejectsGarbage() {
        #expect(throws: MatroskaDemuxer.DemuxError.notMatroska) {
            try MatroskaDemuxer.probe(Data([0x00, 0x01, 0x02, 0x03, 0x04]))
        }
    }
}

@Suite("AetherCore — codec identity + decodability (#476)")
struct MediaCodecTests {

    @Test("Matroska CodecID → video codec + decodability")
    func videoCodecs() {
        #expect(VideoCodec(matroskaCodecID: "V_MPEG4/ISO/AVC") == .h264)
        #expect(VideoCodec(matroskaCodecID: "V_MPEGH/ISO/HEVC") == .hevc)
        #expect(VideoCodec(matroskaCodecID: "V_MPEG4/ISO/ASP") == .other("V_MPEG4/ISO/ASP"))
        #expect(VideoCodec.h264.isAVFoundationDecodable)
        #expect(VideoCodec.hevc.isAVFoundationDecodable)
        #expect(!VideoCodec(matroskaCodecID: "V_VP9").isAVFoundationDecodable)
    }

    @Test("Matroska CodecID → audio codec + decodability")
    func audioCodecs() {
        #expect(AudioCodec(matroskaCodecID: "A_AAC") == .aac)
        #expect(AudioCodec(matroskaCodecID: "A_AAC/MPEG4/LC") == .aac)
        #expect(AudioCodec(matroskaCodecID: "A_AC3") == .ac3)
        #expect(AudioCodec(matroskaCodecID: "A_PCM/INT/LIT") == .pcm)
        #expect(AudioCodec(matroskaCodecID: "A_DTS") == .other("A_DTS"))
        #expect(AudioCodec.aac.isAVFoundationDecodable)
        #expect(!AudioCodec(matroskaCodecID: "A_DTS").isAVFoundationDecodable)
        #expect(!AudioCodec(matroskaCodecID: "A_TRUEHD").isAVFoundationDecodable)
    }
}

@Suite("AetherCore — RemuxEngine routing (#476 Tier 1)")
struct RemuxEngineRoutingTests {
    private let resolver = VideoEngineResolver.standard

    @Test("MKV with H.264 + AAC routes to the remux shim")
    func decodableMKVtoRemux() {
        let d = MediaDescriptor(container: "mkv", videoCodec: .h264, audioCodecs: [.aac])
        #expect(RemuxEngine().canPlay(d))
        #expect(resolver.resolve(d) == .remux)
    }

    @Test("MKV with an undecodable codec (DTS) falls past remux to VLC")
    func undecodableMKVtoVLC() {
        let d = MediaDescriptor(container: "mkv", videoCodec: .h264, audioCodecs: [.dtsLike])
        #expect(!RemuxEngine().canPlay(d))
        #expect(resolver.resolve(d) == .vlc)
    }

    @Test("MKV with unknown codecs (un-probed) stays on VLC — today's behaviour")
    func unprobedMKVtoVLC() {
        let d = MediaDescriptor(container: "mkv")   // no codecs yet
        #expect(!RemuxEngine().canPlay(d))
        #expect(resolver.resolve(d) == .vlc)
    }

    @Test("mp4 stays on AVFoundation (tier 0 wins; remux never claims it)")
    func mp4StaysTier0() {
        let d = MediaDescriptor(container: "mp4", videoCodec: .h264, audioCodecs: [.aac])
        #expect(!RemuxEngine().canPlay(d))
        #expect(resolver.resolve(d) == .avFoundation)
    }

    @Test("HEVC-only MKV (no audio) still remuxes")
    func videoOnlyRemux() {
        let d = MediaDescriptor(container: "mkv", videoCodec: .hevc)
        #expect(resolver.resolve(d) == .remux)
    }
}

private extension AudioCodec {
    /// An undecodable audio codec for routing tests.
    static var dtsLike: AudioCodec { .other("A_DTS") }
}

/// Minimal MP4 box-tree walker for asserting structure in tests.
private enum MP4Probe {
    struct Box { let type: String; let start: Int; let size: Int; var payloadStart: Int { start + 8 } }

    static func be32(_ b: [UInt8], _ i: Int) -> Int {
        (Int(b[i]) << 24) | (Int(b[i+1]) << 16) | (Int(b[i+2]) << 8) | Int(b[i+3])
    }

    /// Top-level boxes in `[from, to)`.
    static func boxes(_ b: [UInt8], from: Int, to: Int) -> [Box] {
        var out: [Box] = []
        var i = from
        while i + 8 <= to {
            let size = be32(b, i)
            guard size >= 8, i + size <= to else { break }
            let type = String(decoding: b[(i+4)..<(i+8)], as: UTF8.self)
            out.append(Box(type: type, start: i, size: size))
            i += size
        }
        return out
    }

    /// Does the fourCC appear anywhere in the byte range?
    static func contains(_ b: [UInt8], fourCC: String) -> Bool {
        let needle = Array(fourCC.utf8)
        guard b.count >= needle.count else { return false }
        for i in 0...(b.count - needle.count) where Array(b[i..<(i+needle.count)]) == needle { return true }
        return false
    }

    static func contains(_ b: [UInt8], subsequence: [UInt8]) -> Bool {
        guard !subsequence.isEmpty, b.count >= subsequence.count else { return false }
        for i in 0...(b.count - subsequence.count) where Array(b[i..<(i+subsequence.count)]) == subsequence { return true }
        return false
    }
}

@Suite("AetherCore — FragmentedMP4Writer init segment (#476 remux)")
struct FragmentedMP4WriterTests {

    private let avcConfig: [UInt8] = [0x01, 0x64, 0x00, 0x1F, 0xFF, 0xE1, 0x00, 0x04, 0x67, 0x42]
    private let aacConfig: [UInt8] = [0x12, 0x10]   // AAC-LC, 48 kHz, stereo

    private func writer() -> FragmentedMP4Writer {
        let video = RemuxTrack(trackID: 1, kind: .video, timescale: 1000,
                               videoCodec: .h264, codecConfig: avcConfig,
                               width: 1920, height: 1080)
        let audio = RemuxTrack(trackID: 2, kind: .audio, timescale: 1000,
                               audioCodec: .aac, codecConfig: aacConfig,
                               channels: 2, sampleRate: 48_000)
        return FragmentedMP4Writer(tracks: [video, audio])
    }

    @Test("init segment is ftyp + moov at the top level")
    func topLevel() {
        let seg = writer().initializationSegment()
        let top = MP4Probe.boxes(seg, from: 0, to: seg.count)
        #expect(top.map(\.type) == ["ftyp", "moov"])
        // Every box's size fits exactly within the buffer.
        #expect(top.last.map { $0.start + $0.size } == seg.count)
    }

    @Test("moov contains mvhd, one trak per track, and mvex")
    func moovChildren() throws {
        let seg = writer().initializationSegment()
        let top = MP4Probe.boxes(seg, from: 0, to: seg.count)
        let moov = try #require(top.first { $0.type == "moov" })
        let children = MP4Probe.boxes(seg, from: moov.payloadStart, to: moov.start + moov.size)
        #expect(children.filter { $0.type == "trak" }.count == 2)
        #expect(children.contains { $0.type == "mvhd" })
        #expect(children.contains { $0.type == "mvex" })
    }

    @Test("sample entries embed avc1/avcC and mp4a/esds with the codec configs")
    func sampleEntries() {
        let seg = writer().initializationSegment()
        #expect(MP4Probe.contains(seg, fourCC: "avc1"))
        #expect(MP4Probe.contains(seg, fourCC: "avcC"))
        #expect(MP4Probe.contains(seg, fourCC: "mp4a"))
        #expect(MP4Probe.contains(seg, fourCC: "esds"))
        #expect(MP4Probe.contains(seg, fourCC: "trex"))
        // The codec configs we passed are actually embedded.
        #expect(MP4Probe.contains(seg, subsequence: avcConfig))
        #expect(MP4Probe.contains(seg, subsequence: aacConfig))
    }

    @Test("media segment is moof + mdat; mdat carries the sample bytes")
    func mediaSegmentStructure() throws {
        let samples = [
            FragmentedMP4Writer.Sample(data: [0xA0, 0xA1, 0xA2], duration: 512, isKeyframe: true, compositionOffset: 0),
            FragmentedMP4Writer.Sample(data: [0xB0, 0xB1], duration: 512, isKeyframe: false, compositionOffset: 0)
        ]
        let track = FragmentedMP4Writer.FragmentTrack(trackID: 1, baseDecodeTime: 0, samples: samples)
        let seg = writer().mediaSegment(sequenceNumber: 1, tracks: [track])

        let top = MP4Probe.boxes(seg, from: 0, to: seg.count)
        #expect(top.map(\.type) == ["moof", "mdat"])

        let moof = try #require(top.first { $0.type == "moof" })
        let moofChildren = MP4Probe.boxes(seg, from: moof.payloadStart, to: moof.start + moof.size)
        #expect(moofChildren.contains { $0.type == "mfhd" })
        #expect(moofChildren.contains { $0.type == "traf" })

        // mdat payload = concatenated sample data.
        let mdat = try #require(top.first { $0.type == "mdat" })
        #expect(Array(seg[mdat.payloadStart..<(mdat.start + mdat.size)]) == [0xA0, 0xA1, 0xA2, 0xB0, 0xB1])
    }

    @Test("trun data_offset points exactly at the first sample byte")
    func dataOffsetResolves() {
        let samples = [FragmentedMP4Writer.Sample(data: [0xCA, 0xFE], duration: 1000, isKeyframe: true, compositionOffset: 0)]
        let track = FragmentedMP4Writer.FragmentTrack(trackID: 1, baseDecodeTime: 0, samples: samples)
        let seg = writer().mediaSegment(sequenceNumber: 1, tracks: [track])

        // moof size + 8 (mdat header) is where sample data starts; default-base-
        // is-moof makes data_offset relative to the moof start, i.e. that value.
        let top = MP4Probe.boxes(seg, from: 0, to: seg.count)
        let moofSize = top.first { $0.type == "moof" }!.size
        #expect(Array(seg[(moofSize + 8)..<(moofSize + 10)]) == [0xCA, 0xFE])
    }

    @Test("RemuxTrack(matroska:) builds H.264/AAC, rejects DTS + subtitles")
    func trackFactory() {
        let h264 = MatroskaTrack(number: 1, type: .video, codecID: "V_MPEG4/ISO/AVC",
                                 codecPrivate: avcConfig, pixelWidth: 1280, pixelHeight: 720)
        let aac = MatroskaTrack(number: 2, type: .audio, codecID: "A_AAC",
                                codecPrivate: aacConfig, channels: 2, sampleRate: 44_100)
        let dts = MatroskaTrack(number: 3, type: .audio, codecID: "A_DTS", codecPrivate: [0x00])
        let subs = MatroskaTrack(number: 4, type: .subtitle, codecID: "S_TEXT/UTF8")
        let noConfig = MatroskaTrack(number: 5, type: .video, codecID: "V_MPEG4/ISO/AVC", codecPrivate: nil)

        #expect(RemuxTrack(matroska: h264, trackID: 1, timescaleTicksPerSecond: 1000)?.kind == .video)
        #expect(RemuxTrack(matroska: aac, trackID: 2, timescaleTicksPerSecond: 1000)?.kind == .audio)
        #expect(RemuxTrack(matroska: dts, trackID: 3, timescaleTicksPerSecond: 1000) == nil)
        #expect(RemuxTrack(matroska: subs, trackID: 4, timescaleTicksPerSecond: 1000) == nil)
        #expect(RemuxTrack(matroska: noConfig, trackID: 5, timescaleTicksPerSecond: 1000) == nil)
    }
}

@Suite("AetherCore — ByteSource (#476 remux)")
struct ByteSourceTests {

    @Test("DataByteSource reads clamped ranges without copying the whole buffer")
    func dataByteSource() {
        let source = DataByteSource(Data([0x00, 0x01, 0x02, 0x03, 0x04]))
        #expect(source.count == 5)
        #expect(source.bytes(at: 1, length: 2) == [0x01, 0x02])
        #expect(source.bytes(at: 3, length: 10) == [0x03, 0x04])   // clamped at EOF
        #expect(source.bytes(at: 5, length: 1) == [])              // past the end
        #expect(source.bytes(at: 0, length: 0) == [])
    }

    @Test("DataByteSource honours a non-zero Data startIndex (sliced Data)")
    func slicedData() {
        // A Data slice keeps a non-zero startIndex; offsets here are 0-based.
        let sliced = Data([0xFF, 0xAA, 0xBB, 0xCC]).dropFirst()   // [0xAA,0xBB,0xCC], startIndex 1
        let source = DataByteSource(sliced)
        #expect(source.count == 3)
        #expect(source.bytes(at: 0, length: 2) == [0xAA, 0xBB])
    }

    @Test("EBMLReader over a ByteSource reads the same as over raw bytes")
    func readerOverSource() {
        var reader = EBMLReader(DataByteSource(Data([0x1A, 0x45, 0xDF, 0xA3, 0x81])))
        #expect(reader.readElementID() == 0x1A45DFA3)
        #expect(reader.readSize() == .known(1))
    }
}

@Suite("AetherCore — MatroskaRemuxer end-to-end (#476 remux)")
struct MatroskaRemuxerTests {

    private let avcConfig: [UInt8] = [0x01, 0x64, 0x00, 0x1F, 0xFF, 0xE1, 0xDE, 0xAD]
    private let frame0: [UInt8] = [0xF0, 0x00, 0x00, 0x01]
    private let frame1: [UInt8] = [0xF1, 0x11]

    @Test("probes a remuxable MKV into one video track")
    func initSucceeds() throws {
        let data = MKV.remuxableSample(avcConfig: avcConfig, frame0: frame0, frame1: frame1)
        let remuxer = try #require(MatroskaRemuxer(data: data))
        #expect(remuxer.tracks.count == 1)
        #expect(remuxer.tracks.first?.kind == .video)
        #expect(remuxer.tracks.first?.videoCodec == .h264)
    }

    @Test("non-remuxable MKV (no CodecPrivate) → init returns nil")
    func initFailsWithoutConfig() {
        // MKV.sample()'s tracks carry no CodecPrivate, so nothing is packageable.
        #expect(MatroskaRemuxer(data: MKV.sample()) == nil)
    }

    @Test("remuxAll emits a valid fMP4 stream: ftyp + moov + moof + mdat")
    func fullStream() throws {
        let data = MKV.remuxableSample(avcConfig: avcConfig, frame0: frame0, frame1: frame1)
        let remuxer = try #require(MatroskaRemuxer(data: data))
        let out = remuxer.remuxAll()

        let top = MP4Probe.boxes(out, from: 0, to: out.count)
        #expect(top.map(\.type) == ["ftyp", "moov", "moof", "mdat"])
        // Every top-level box accounts for the whole buffer with none left over.
        #expect(top.last.map { $0.start + $0.size } == out.count)

        // The avcC config and both frames made it into the output.
        #expect(MP4Probe.contains(out, subsequence: avcConfig))
        #expect(MP4Probe.contains(out, subsequence: frame0))
        #expect(MP4Probe.contains(out, subsequence: frame1))

        // mdat payload is exactly the two frames, in order.
        let mdat = try #require(top.first { $0.type == "mdat" })
        #expect(Array(out[mdat.payloadStart..<(mdat.start + mdat.size)]) == frame0 + frame1)
    }

    @Test("stream index total length matches the read-back, output is valid fMP4")
    func streamIndexLength() throws {
        let data = MKV.remuxableTwoCluster(avcConfig: avcConfig)
        let remuxer = try #require(MatroskaRemuxer(data: data))
        let index = remuxer.buildStreamIndex()

        let whole = remuxer.readBytes(offset: 0, length: index.totalLength, index: index)
        #expect(whole.count == index.totalLength)

        // Two clusters → ftyp + moov + two moof/mdat pairs.
        let top = MP4Probe.boxes(whole, from: 0, to: whole.count)
        #expect(top.prefix(2).map(\.type) == ["ftyp", "moov"])
        #expect(top.filter { $0.type == "moof" }.count == 2)
        #expect(top.filter { $0.type == "mdat" }.count == 2)
        #expect(top.last.map { $0.start + $0.size } == whole.count)
    }

    @Test("partial range reads are consistent with the whole stream")
    func partialReadsConsistent() throws {
        let data = MKV.remuxableTwoCluster(avcConfig: avcConfig)
        let remuxer = try #require(MatroskaRemuxer(data: data))
        let index = remuxer.buildStreamIndex()
        let whole = remuxer.readBytes(offset: 0, length: index.totalLength, index: index)

        // A range spanning the init segment into the first media segment, a
        // mid-stream range, and the tail — each must equal the whole sliced.
        for (offset, length) in [(0, 20), (10, whole.count - 10), (whole.count - 5, 5), (index.initLength - 3, 12)] {
            let slice = remuxer.readBytes(offset: offset, length: length, index: index)
            #expect(slice == Array(whole[offset..<min(offset + length, whole.count)]))
        }
    }

    @Test("decode order is preserved (frames are NOT PTS-sorted) — B-frame fix")
    func decodeOrderPreserved() throws {
        // One cluster, three video frames in DECODE order with reordered PTS —
        // the classic B-frame pattern: I@0, P@80, B@40. PTS-sorting (the old bug)
        // would reorder to I,B,P and scramble the decoder; decode order must win.
        let fA: [UInt8] = [0x0A, 0x0A], fB: [UInt8] = [0x0B, 0x0B], fC: [UInt8] = [0x0C, 0x0C]
        let videoEntry = MKV.el(MKV.trackEntry,
            MKV.el(MKV.trackNumber, MKV.uint(1)) +
            MKV.el(MKV.trackType, MKV.uint(1)) +
            MKV.el(MKV.codecID, Array("V_MPEG4/ISO/AVC".utf8)) +
            MKV.el(MKV.codecPrivate, avcConfig) +
            MKV.el(MKV.video, MKV.el(MKV.pixelWidth, MKV.uint(640)) + MKV.el(MKV.pixelHeight, MKV.uint(360))))
        let cluster = MKV.el(MKV.cluster,
            MKV.el(MKV.timestamp, MKV.uint(0)) +
            MKV.el(MKV.simpleBlock, MKV.blockPayload(track: 1, relTs: 0,  flags: 0x80, frame: fA)) +
            MKV.el(MKV.simpleBlock, MKV.blockPayload(track: 1, relTs: 80, flags: 0x00, frame: fB)) +
            MKV.el(MKV.simpleBlock, MKV.blockPayload(track: 1, relTs: 40, flags: 0x00, frame: fC)))
        let data = Data(MKV.el(MKV.ebmlHeader, []) + MKV.el(MKV.segment,
            MKV.el(MKV.info, MKV.el(MKV.timestampScale, MKV.uint(1_000_000))) +
            MKV.el(MKV.tracks, videoEntry) + cluster))

        let remuxer = try #require(MatroskaRemuxer(data: data))
        let out = remuxer.remuxAll()
        let mdat = try #require(MP4Probe.boxes(out, from: 0, to: out.count).first { $0.type == "mdat" })
        // Decode order A,B,C — NOT the PTS-sorted A,C,B.
        #expect(Array(out[mdat.payloadStart..<(mdat.start + mdat.size)]) == fA + fB + fC)
    }

    @Test("sample durations come from successive frame timestamps")
    func durations() throws {
        let data = MKV.remuxableSample(avcConfig: avcConfig, frame0: frame0, frame1: frame1)
        let remuxer = try #require(MatroskaRemuxer(data: data))
        let frames = [
            MatroskaFrame(trackNumber: 1, timestampTicks: 0, isKeyframe: true, data: frame0),
            MatroskaFrame(trackNumber: 1, timestampTicks: 40, isKeyframe: false, data: frame1)
        ]
        let seg = remuxer.mediaSegment(from: frames, sequenceNumber: 1)
        // The first sample's duration (40) should appear as a u32 in the trun.
        #expect(MP4Probe.contains(seg, subsequence: [0x00, 0x00, 0x00, 0x28]))   // 40
    }
}

@Suite("AetherCore — MP4Box writer (#476 remux)")
struct MP4BoxTests {

    @Test("big-endian integer writers")
    func byteWriter() {
        var w = MP4ByteWriter()
        w.u16(0x0102)
        w.u32(0x0304_0506)
        w.u64(0x0708_090A_0B0C_0D0E)
        #expect(w.bytes == [0x01, 0x02,
                            0x03, 0x04, 0x05, 0x06,
                            0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E])
    }

    @Test("box = size(incl. header) + type + payload")
    func box() {
        let b = MP4Box.box("test", [0x01, 0x02])
        #expect(b == [0x00, 0x00, 0x00, 0x0A, 0x74, 0x65, 0x73, 0x74, 0x01, 0x02])
    }

    @Test("full box inserts version + 24-bit flags")
    func fullBox() {
        let b = MP4Box.fullBox("abcd", version: 1, flags: 0x000002, [0xFF])
        // size 13 = 8 header + 1 version + 3 flags + 1 payload
        #expect(b == [0x00, 0x00, 0x00, 0x0D, 0x61, 0x62, 0x63, 0x64,
                      0x01, 0x00, 0x00, 0x02, 0xFF])
    }

    @Test("container box size accounts for nested children")
    func container() {
        let inner = MP4Box.box("inn1", [0xAA])           // 9 bytes
        let outer = MP4Box.container("outr", [inner])
        #expect(outer.count == inner.count + 8)
        #expect(Array(outer[0..<4]) == [0x00, 0x00, 0x00, UInt8(inner.count + 8)])
    }

    @Test("four-CC shorter than 4 chars is space-padded")
    func fourCCPadding() {
        let b = MP4Box.box("id", [])
        #expect(Array(b[4..<8]) == [0x69, 0x64, 0x20, 0x20])   // "id  "
    }

    @Test("ftyp brand box")
    func ftyp() {
        let b = MP4Box.ftyp()
        #expect(b.count == 36)                                 // 8 + 4 + 4 + 5*4
        #expect(Array(b[4..<8]) == Array("ftyp".utf8))
        #expect(Array(b[8..<12]) == Array("isom".utf8))        // major brand
        #expect(Array(b[12..<16]) == [0x00, 0x00, 0x02, 0x00]) // minor version
    }
}

@Suite("AetherCore — MatroskaFrameReader (#476 remux)")
struct MatroskaFrameReaderTests {

    @Test("unlaced SimpleBlocks → frames with track, abs timestamp, keyframe, data")
    func simpleBlocks() throws {
        let b1 = MKV.el(MKV.simpleBlock, MKV.blockPayload(track: 1, relTs: 16, flags: 0x80, frame: [0xAA, 0xBB, 0xCC]))
        let b2 = MKV.el(MKV.simpleBlock, MKV.blockPayload(track: 1, relTs: 32, flags: 0x00, frame: [0xDD, 0xEE]))
        let clusterEl = MKV.el(MKV.cluster, MKV.el(MKV.timestamp, MKV.uint(100)) + b1 + b2)
        let data = Data(clusterEl)

        let result = try #require(MatroskaFrameReader.readCluster(data, at: 0))
        #expect(result.frames.count == 2)
        #expect(result.nextOffset == clusterEl.count)

        let f1 = result.frames[0]
        #expect(f1.trackNumber == 1)
        #expect(f1.timestampTicks == 116)   // cluster 100 + relative 16
        #expect(f1.isKeyframe)
        #expect(f1.data == [0xAA, 0xBB, 0xCC])

        let f2 = result.frames[1]
        #expect(f2.timestampTicks == 132)
        #expect(!f2.isKeyframe)
        #expect(f2.data == [0xDD, 0xEE])
    }

    @Test("negative relative timestamp resolves below the cluster base")
    func negativeRelativeTimestamp() throws {
        let b = MKV.el(MKV.simpleBlock, MKV.blockPayload(track: 1, relTs: -10, flags: 0x80, frame: [0x01]))
        let clusterEl = MKV.el(MKV.cluster, MKV.el(MKV.timestamp, MKV.uint(50)) + b)
        let result = try #require(MatroskaFrameReader.readCluster(Data(clusterEl), at: 0))
        #expect(result.frames.first?.timestampTicks == 40)
    }

    @Test("fixed lacing splits the payload into equal frames")
    func fixedLacing() throws {
        // flags 0x04 → lacing field 0b10 = fixed; countMinus1 = 1 → 2 frames; 4 bytes → 2 each.
        let payload = MKV.blockPayload(track: 1, relTs: 0, flags: 0x04, lace: [0x01], frame: [0x11, 0x22, 0x33, 0x44])
        let clusterEl = MKV.el(MKV.cluster, MKV.el(MKV.timestamp, MKV.uint(0)) + MKV.el(MKV.simpleBlock, payload))
        let result = try #require(MatroskaFrameReader.readCluster(Data(clusterEl), at: 0))
        #expect(result.frames.map(\.data) == [[0x11, 0x22], [0x33, 0x44]])
    }

    @Test("BlockGroup keyframe is decided by ReferenceBlock presence")
    func blockGroupKeyframe() throws {
        let blockPayload = MKV.blockPayload(track: 1, relTs: 0, flags: 0x00, frame: [0x99])
        let keyframeGroup = MKV.el(MKV.blockGroup, MKV.el(MKV.block, blockPayload))
        let interGroup = MKV.el(MKV.blockGroup,
            MKV.el(MKV.block, blockPayload) + MKV.el(MKV.referenceBlock, [0x01]))
        let clusterEl = MKV.el(MKV.cluster, MKV.el(MKV.timestamp, MKV.uint(0)) + keyframeGroup + interGroup)

        let result = try #require(MatroskaFrameReader.readCluster(Data(clusterEl), at: 0))
        #expect(result.frames.count == 2)
        #expect(result.frames[0].isKeyframe)    // no ReferenceBlock
        #expect(!result.frames[1].isKeyframe)   // has ReferenceBlock
    }

    @Test("readAllFrames walks consecutive clusters")
    func multipleClusters() {
        func cluster(base: UInt64, frame: [UInt8]) -> [UInt8] {
            MKV.el(MKV.cluster,
                   MKV.el(MKV.timestamp, MKV.uint(base)) +
                   MKV.el(MKV.simpleBlock, MKV.blockPayload(track: 1, relTs: 0, flags: 0x80, frame: frame)))
        }
        let data = Data(cluster(base: 0, frame: [0x01]) + cluster(base: 1000, frame: [0x02]))
        let frames = MatroskaFrameReader.readAllFrames(data, from: 0)
        #expect(frames.map(\.timestampTicks) == [0, 1000])
        #expect(frames.map(\.data) == [[0x01], [0x02]])
    }
}
