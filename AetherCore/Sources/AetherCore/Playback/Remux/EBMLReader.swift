import Foundation

/// Low-level reader for **EBML** (Extensible Binary Meta Language) — the binary
/// framing Matroska (`.mkv`) is built on. This is the bedrock of the pure-Swift
/// remux shim (#476, Tier 1): it turns a byte source into element IDs, sizes,
/// and primitive values; `MatroskaDemuxer` layers the container semantics on top.
///
/// Reads over a `ByteSource`, so it never copies the whole file — only the bytes
/// each call touches, which keeps multi-GB rips off the heap.
///
/// EBML encodes every integer as a **variable-length integer (vint)**: the
/// position of the first set bit in the leading byte gives the total length
/// (1–8 bytes). Element **IDs keep** that marker bit (the ID *is* the stored
/// pattern, e.g. `0x1A45DFA3` for the EBML header); **sizes and values strip**
/// it (the marker only encodes length, not data).
///
/// Bounds-checked: every read returns `nil` rather than trapping past the end,
/// so a truncated/corrupt file degrades to "can't remux" instead of a crash.
struct EBMLReader {
    /// The backing bytes — exposed so callers can spawn a second reader over the
    /// same source at a different offset (e.g. re-reading a sub-element).
    let source: any ByteSource
    /// Cursor — the next byte to read. Callers seek via `seek(to:)`.
    private(set) var offset: Int

    init(_ source: any ByteSource, offset: Int = 0) {
        self.source = source
        self.offset = offset
    }

    init(_ data: Data, offset: Int = 0) {
        self.init(DataByteSource(data), offset: offset)
    }

    init(bytes: [UInt8], offset: Int = 0) {
        self.init(DataByteSource(Data(bytes)), offset: offset)
    }

    var count: Int { source.count }
    var isAtEnd: Bool { offset >= source.count }
    var remaining: Int { max(0, source.count - offset) }

    mutating func seek(to newOffset: Int) { offset = newOffset }
    mutating func skip(_ n: Int) { offset += n }

    /// One byte at the cursor without advancing.
    private func peek() -> UInt8? {
        source.bytes(at: offset, length: 1).first
    }

    /// Exactly `length` bytes at the cursor (bounds-checked), advancing past them.
    private mutating func take(_ length: Int) -> [UInt8]? {
        guard length >= 0, offset + length <= source.count else { return nil }
        let slice = source.bytes(at: offset, length: length)
        guard slice.count == length else { return nil }
        offset += length
        return slice
    }

    // MARK: - vint length

    /// Total byte length encoded by a vint's leading byte (1–8), or `nil` if the
    /// byte is `0x00` (length would exceed 8 — invalid / not the start of a vint).
    static func vintLength(firstByte: UInt8) -> Int? {
        guard firstByte != 0 else { return nil }
        return firstByte.leadingZeroBitCount + 1
    }

    // MARK: - Element ID

    /// Read an element ID — the vint **with** its marker bit kept, as stored in
    /// the file. 1–4 bytes; longer is rejected (no Matroska ID exceeds 4 bytes).
    mutating func readElementID() -> UInt32? {
        guard let first = peek(), let length = Self.vintLength(firstByte: first), length <= 4 else { return nil }
        guard let raw = take(length) else { return nil }
        var value: UInt32 = 0
        for byte in raw { value = (value << 8) | UInt32(byte) }
        return value
    }

    // MARK: - Size / unsigned vint

    /// A size vint: a concrete byte count, or EBML's "unknown size" sentinel.
    enum Size: Equatable {
        case known(UInt64)
        case unknown
    }

    /// Read a size vint — marker bit **stripped**. `.unknown` when every value
    /// bit is `1` (EBML's reserved "unknown size").
    mutating func readSize() -> Size? {
        guard let (value, _, allOnes) = readUnsignedVint() else { return nil }
        return allOnes ? .unknown : .known(value)
    }

    /// Read an unsigned vint, marker stripped. Returns the value, its byte
    /// length, and whether all value bits were set (the "unknown size" sentinel).
    private mutating func readUnsignedVint() -> (value: UInt64, length: Int, allOnes: Bool)? {
        guard let first = peek(), let length = Self.vintLength(firstByte: first), length <= 8 else { return nil }
        guard let raw = take(length) else { return nil }
        let firstMask: UInt8 = length == 8 ? 0x00 : (0xFF >> length)
        var value = UInt64(raw[0] & firstMask)
        var allOnes = (raw[0] & firstMask) == firstMask
        if length > 1 {
            for i in 1..<length {
                value = (value << 8) | UInt64(raw[i])
                if raw[i] != 0xFF { allOnes = false }
            }
        }
        return (value, length, allOnes)
    }

    /// Read an unsigned vint and return its value (marker stripped), ignoring the
    /// "unknown size" distinction. For in-block track numbers and lace sizes.
    mutating func readVInt() -> UInt64? {
        readUnsignedVint()?.value
    }

    /// Read a **signed** vint (EBML lacing size deltas): the unsigned value minus
    /// the bias `2^(7·length−1) − 1`, centring the range.
    mutating func readSignedVInt() -> Int64? {
        guard let (value, length, _) = readUnsignedVint() else { return nil }
        let bias = (Int64(1) << (7 * length - 1)) - 1
        return Int64(value) - bias
    }

    // MARK: - Fixed-width primitives (element payloads)

    /// Big-endian unsigned integer of `length` bytes (0–8).
    mutating func readUInt(length: Int) -> UInt64? {
        guard length >= 0, length <= 8, let raw = take(length) else { return nil }
        var value: UInt64 = 0
        for byte in raw { value = (value << 8) | UInt64(byte) }
        return value
    }

    /// Big-endian signed integer of `length` bytes (sign-extended).
    mutating func readInt(length: Int) -> Int64? {
        guard length >= 1, length <= 8 else { return length == 0 ? 0 : nil }
        guard let raw = readUInt(length: length) else { return nil }
        let shift = (8 - length) * 8
        return Int64(bitPattern: raw << shift) >> shift
    }

    /// EBML float element: 4 bytes → `Float`, 8 → `Double`, 0 → 0.
    mutating func readFloat(length: Int) -> Double? {
        switch length {
        case 0: return 0
        case 4:
            guard let bits = readUInt(length: 4) else { return nil }
            return Double(Float(bitPattern: UInt32(truncatingIfNeeded: bits)))
        case 8:
            guard let bits = readUInt(length: 8) else { return nil }
            return Double(bitPattern: bits)
        default:
            return nil
        }
    }

    /// `length` bytes as a UTF-8 string, trimming trailing NUL padding.
    mutating func readString(length: Int) -> String? {
        guard let raw = take(length) else { return nil }
        var end = raw.count
        while end > 0, raw[end - 1] == 0 { end -= 1 }
        return String(decoding: raw[0..<end], as: UTF8.self)
    }

    /// `length` raw bytes, advancing the cursor.
    mutating func readBytes(length: Int) -> [UInt8]? {
        take(length)
    }
}
