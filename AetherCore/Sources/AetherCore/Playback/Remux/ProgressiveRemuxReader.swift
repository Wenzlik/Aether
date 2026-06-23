import Foundation

/// Serves the bytes of a **progressive** remuxed MP4 (#476) on demand: the
/// init segment (`ftyp`+`moov`+`mdat` header) is materialised once, and `mdat`
/// payload bytes are read from the source file per sample as ranges are
/// requested — so a multi-GB rip never lands on the heap.
///
/// `moov` lays the tracks out as contiguous runs in `mdat` (video, audio, then
/// subtitle). Each A/V sample maps to a byte range in the source file; subtitle
/// samples are generated (WebVTT boxes) and held inline. A read range is split
/// across the samples it overlaps and stitched back together.
public final class ProgressiveRemuxReader: @unchecked Sendable {
    /// One A/V sample's place in the output and the source bytes that back it.
    struct AVSample: Sendable {
        let cumOffset: Int    // byte offset within the track's region
        let sourceOffset: Int // byte offset in the source file
        let size: Int
    }

    /// A contiguous track run in `mdat`.
    struct Region: Sendable {
        let outputStart: Int
        let size: Int
        /// A/V: per-sample source map (sorted by `cumOffset`). Subtitle: nil.
        let avSamples: [AVSample]?
        /// Subtitle: the generated WebVTT bytes for the whole region. A/V: nil.
        let inlineData: [UInt8]?
    }

    public let contentLength: Int
    private let source: any ByteSource
    private let initSegment: [UInt8]
    private let regions: [Region]

    init(source: any ByteSource, initSegment: [UInt8], regions: [Region], contentLength: Int) {
        self.source = source
        self.initSegment = initSegment
        self.regions = regions
        self.contentLength = contentLength
    }

    /// Bytes for `[offset, offset+length)` of the progressive output.
    public func read(offset: Int, length: Int) -> [UInt8] {
        let end = min(offset + length, contentLength)
        guard offset >= 0, offset < end else { return [] }
        var result: [UInt8] = []

        // Init-segment region.
        if offset < initSegment.count {
            result += initSegment[offset..<min(end, initSegment.count)]
        }

        // Overlapping track regions in mdat.
        for region in regions {
            let regionEnd = region.outputStart + region.size
            guard regionEnd > offset, region.outputStart < end else { continue }
            let lo = max(offset, region.outputStart) - region.outputStart
            let hi = min(end, regionEnd) - region.outputStart
            if lo < hi { result += regionBytes(region, from: lo, to: hi) }
        }
        return result
    }

    /// Bytes `[localLo, localHi)` within one region's payload.
    private func regionBytes(_ region: Region, from localLo: Int, to localHi: Int) -> [UInt8] {
        if let data = region.inlineData {
            return Array(data[localLo..<min(localHi, data.count)])
        }
        guard let samples = region.avSamples, !samples.isEmpty else { return [] }

        var out: [UInt8] = []
        var i = sampleIndex(samples, containing: localLo)
        while i < samples.count {
            let sample = samples[i]
            if sample.cumOffset >= localHi { break }
            let from = max(localLo, sample.cumOffset)
            let to = min(localHi, sample.cumOffset + sample.size)
            if from < to {
                let sourceFrom = sample.sourceOffset + (from - sample.cumOffset)
                out += source.bytes(at: sourceFrom, length: to - from)
            }
            i += 1
        }
        return out
    }

    /// First sample whose byte range reaches `position` (binary search on the
    /// cumulative offsets).
    private func sampleIndex(_ samples: [AVSample], containing position: Int) -> Int {
        var lo = 0, hi = samples.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].cumOffset + samples[mid].size <= position {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }
}
