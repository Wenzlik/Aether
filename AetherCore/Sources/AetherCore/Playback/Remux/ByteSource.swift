import Foundation

/// Random-access byte source for the remux pipeline (#476). Decouples the
/// demuxer from *where* the bytes live: an in-memory / memory-mapped `Data`
/// today, an SMB byte-range reader later. The point is that the demuxer reads
/// only the bytes it touches — never copying a multi-GB file into an array
/// (which the old `[UInt8](data)` path did on every cluster read).
///
/// Synchronous on purpose: a memory-mapped file faults in only the pages read,
/// so small synchronous reads stay cheap. A network-backed source wraps a
/// buffering layer to keep per-read cost down.
public protocol ByteSource: Sendable {
    /// Total length in bytes.
    var count: Int { get }
    /// Bytes in `[offset, offset+length)`, clamped to the available range —
    /// returns fewer than `length` only at EOF, empty if `offset` is past the end.
    func bytes(at offset: Int, length: Int) -> [UInt8]
}

/// `ByteSource` over a `Data` value. Backing a memory-mapped `Data`
/// (`Data(contentsOf:options:.mappedIfSafe)`) means a local file is read
/// page-by-page on demand, not loaded whole.
public struct DataByteSource: ByteSource {
    private let data: Data

    public init(_ data: Data) { self.data = data }

    public var count: Int { data.count }

    public func bytes(at offset: Int, length: Int) -> [UInt8] {
        guard offset >= 0, offset < data.count, length > 0 else { return [] }
        let end = min(offset + length, data.count)
        // Data is indexed from its own startIndex; offsets here are 0-based.
        let lo = data.startIndex + offset
        let hi = data.startIndex + end
        return [UInt8](data[lo..<hi])
    }
}
