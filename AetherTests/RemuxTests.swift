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
