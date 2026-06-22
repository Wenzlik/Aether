import Foundation

/// Stateful, cached byte reader over a `MatroskaRemuxer`'s output (#476). The
/// AVFoundation resource loader asks for many overlapping byte ranges (often the
/// same fragment in several chunks); regenerating a cluster's fMP4 segment on
/// every request made playback stall for seconds (black screen). This builds the
/// index once and caches the last few generated segments, so sequential reads
/// regenerate each cluster at most once.
///
/// Used from a single serial loader queue, so its mutable cache needs no locking
/// (`@unchecked Sendable`).
public final class RemuxByteReader: @unchecked Sendable {
    private let remuxer: MatroskaRemuxer
    private let index: MatroskaRemuxer.StreamIndex
    private var initSegment: [UInt8]?
    /// Small MRU cache of generated segments, keyed by sequence number. AVPlayer
    /// reads roughly forward, so a handful covers the overlap between requests.
    private var cache: [(sequence: UInt32, bytes: [UInt8])] = []
    private let cacheLimit = 6

    public init(_ remuxer: MatroskaRemuxer) {
        self.remuxer = remuxer
        self.index = remuxer.buildStreamIndex()
    }

    /// Total size of the remuxed output (HTTP `Content-Length` / asset size).
    public var contentLength: Int { index.totalLength }

    /// Bytes for `[offset, offset+length)` of the remuxed output, reusing cached
    /// segments where possible.
    public func read(offset: Int, length: Int) -> [UInt8] {
        let end = min(offset + length, index.totalLength)
        guard offset >= 0, offset < end else { return [] }
        var result: [UInt8] = []

        if offset < index.initLength {
            let segment = initializationSegment()
            result += segment[offset..<min(end, index.initLength)]
        }

        for segment in index.segments {
            let segmentEnd = segment.outputOffset + segment.length
            guard segmentEnd > offset, segment.outputOffset < end else { continue }
            let bytes = segmentBytes(segment)
            let lo = max(offset, segment.outputOffset) - segment.outputOffset
            let hi = min(end, segmentEnd) - segment.outputOffset
            if lo < hi { result += bytes[lo..<hi] }
        }
        return result
    }

    private func initializationSegment() -> [UInt8] {
        if let initSegment { return initSegment }
        let segment = remuxer.initializationSegment()
        initSegment = segment
        return segment
    }

    private func segmentBytes(_ segment: MatroskaRemuxer.StreamIndex.Segment) -> [UInt8] {
        if let hit = cache.first(where: { $0.sequence == segment.sequence }) { return hit.bytes }
        let bytes = remuxer.segmentData(segment)
        cache.append((segment.sequence, bytes))
        if cache.count > cacheLimit { cache.removeFirst() }
        return bytes
    }
}
