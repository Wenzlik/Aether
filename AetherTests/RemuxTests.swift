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
