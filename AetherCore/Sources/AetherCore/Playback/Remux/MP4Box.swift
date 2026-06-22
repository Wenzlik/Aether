import Foundation

/// Big-endian byte accumulator for building ISOBMFF / MP4 structures. All
/// multi-byte integers in MP4 are big-endian; this centralises that so box
/// builders read cleanly (#476 remux output).
struct MP4ByteWriter {
    private(set) var bytes: [UInt8] = []

    mutating func u8(_ v: UInt8) { bytes.append(v) }

    mutating func u16(_ v: UInt16) {
        bytes.append(UInt8(v >> 8))
        bytes.append(UInt8(v & 0xFF))
    }

    mutating func u32(_ v: UInt32) {
        bytes.append(UInt8((v >> 24) & 0xFF))
        bytes.append(UInt8((v >> 16) & 0xFF))
        bytes.append(UInt8((v >> 8) & 0xFF))
        bytes.append(UInt8(v & 0xFF))
    }

    mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }

    mutating func u64(_ v: UInt64) {
        u32(UInt32(v >> 32))
        u32(UInt32(v & 0xFFFF_FFFF))
    }

    /// A 4-character box type / brand. Must be exactly 4 ASCII bytes; shorter is
    /// space-padded, longer truncated (callers pass valid four-CCs).
    mutating func fourCC(_ s: String) {
        var cc = Array(s.utf8.prefix(4))
        while cc.count < 4 { cc.append(0x20) }
        bytes.append(contentsOf: cc)
    }

    mutating func append(_ other: [UInt8]) { bytes.append(contentsOf: other) }
    mutating func append(_ other: MP4ByteWriter) { bytes.append(contentsOf: other.bytes) }
}

/// ISOBMFF box constructors. A *box* is `[size:u32][type:4cc][payload]`, where
/// `size` counts the 8-byte header too. A *full box* inserts a 1-byte version
/// and 3-byte flags before the payload.
enum MP4Box {

    /// `[size][type][payload]`.
    static func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        var w = MP4ByteWriter()
        w.u32(UInt32(payload.count + 8))
        w.fourCC(type)
        w.append(payload)
        return w.bytes
    }

    /// Convenience: a box whose payload is itself one or more child boxes.
    static func container(_ type: String, _ children: [[UInt8]]) -> [UInt8] {
        box(type, children.flatMap { $0 })
    }

    /// `[size][type][version][flags:24][payload]`.
    static func fullBox(_ type: String, version: UInt8, flags: UInt32, _ payload: [UInt8]) -> [UInt8] {
        var w = MP4ByteWriter()
        w.u8(version)
        w.u8(UInt8((flags >> 16) & 0xFF))
        w.u8(UInt8((flags >> 8) & 0xFF))
        w.u8(UInt8(flags & 0xFF))
        w.append(payload)
        return box(type, w.bytes)
    }

    /// The `ftyp` brand box that opens the file. Brands chosen for broad
    /// AVFoundation compatibility with fragmented MP4.
    static func ftyp() -> [UInt8] {
        var w = MP4ByteWriter()
        w.fourCC("isom")            // major brand
        w.u32(0x0000_0200)          // minor version
        for brand in ["isom", "iso2", "avc1", "iso6", "mp41"] { w.fourCC(brand) }
        return box("ftyp", w.bytes)
    }
}
