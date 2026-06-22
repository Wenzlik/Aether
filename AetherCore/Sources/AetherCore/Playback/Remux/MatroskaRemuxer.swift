import Foundation

/// Drives the Tier 1 remux pipeline end to end (#476): probe a Matroska file,
/// build the fMP4 initialization segment, then turn its clusters into fMP4
/// media segments. Ties `MatroskaDemuxer` + `MatroskaFrameReader` to
/// `FragmentedMP4Writer`.
///
/// `init?` fails (returns `nil`) when the file isn't Matroska or carries no
/// track the muxer can package (H.264/HEVC video + AAC audio today) — the caller
/// then falls back to another engine. Sample durations are derived from frame
/// timestamps; because the track timescale is set to the Matroska tick rate,
/// timestamps map across 1:1.
public struct MatroskaRemuxer {
    /// Tracks that will appear in the fMP4 output (packageable ones only).
    public let tracks: [RemuxTrack]

    private let data: Data
    private let firstClusterOffset: Int?
    /// Matroska track number → fMP4 track id.
    private let trackIDByNumber: [UInt64: UInt32]
    private let writer: FragmentedMP4Writer

    public init?(data: Data) {
        guard let segment = try? MatroskaDemuxer.probe(data) else { return nil }

        // Track timescale = ticks per second implied by the Matroska timestamp
        // scale (default 1 ms → 1000).
        let timescale = UInt32(max(1, 1_000_000_000 / segment.info.timestampScaleNs))

        var remuxTracks: [RemuxTrack] = []
        var idByNumber: [UInt64: UInt32] = [:]
        var nextID: UInt32 = 1
        for track in segment.tracks {
            guard let remux = RemuxTrack(matroska: track, trackID: nextID,
                                         timescaleTicksPerSecond: timescale) else { continue }
            remuxTracks.append(remux)
            idByNumber[track.number] = nextID
            nextID += 1
        }
        guard !remuxTracks.isEmpty else { return nil }

        self.tracks = remuxTracks
        self.data = data
        self.firstClusterOffset = segment.firstClusterOffset
        self.trackIDByNumber = idByNumber
        self.writer = FragmentedMP4Writer(tracks: remuxTracks)
    }

    /// `ftyp` + `moov` — the fMP4 init segment AVPlayer opens first.
    public func initializationSegment() -> [UInt8] {
        writer.initializationSegment()
    }

    /// Remux the whole file into one self-contained fMP4 byte stream
    /// (init + a single media segment). Used for small files and tests; the
    /// streaming path emits per-cluster segments via `mediaSegment(from:_:)`.
    public func remuxAll() -> [UInt8] {
        var output = initializationSegment()
        guard let start = firstClusterOffset else { return output }
        let frames = MatroskaFrameReader.readAllFrames(data, from: start)
        output += mediaSegment(from: frames, sequenceNumber: 1)
        return output
    }

    // MARK: - Range-addressable streaming

    /// A map of the remuxed output's byte layout, built in one pass over the
    /// source. Lets a server (the SMB range proxy / an AVFoundation resource
    /// loader) answer arbitrary byte-range requests **without** holding the whole
    /// remuxed file in memory — only segment sizes + their source cluster offset
    /// are kept; the bytes are regenerated on demand from the cluster.
    public struct StreamIndex: Sendable {
        public let totalLength: Int
        let initLength: Int
        let segments: [Segment]

        struct Segment: Sendable {
            let outputOffset: Int   // byte offset of this segment in the output
            let length: Int
            let clusterOffset: Int  // source offset to regenerate it from
            let sequence: UInt32
        }
    }

    /// One pass over the clusters, recording each media segment's output offset,
    /// length, and source cluster — enough to serve any range and to report the
    /// total content length (needed for HTTP `Content-Length` / asset sizing).
    public func buildStreamIndex() -> StreamIndex {
        let initLength = initializationSegment().count
        var segments: [StreamIndex.Segment] = []
        var outputOffset = initLength
        var sequence: UInt32 = 1
        var clusterOffset = firstClusterOffset
        while let start = clusterOffset, start < data.count {
            guard let (frames, next) = MatroskaFrameReader.readCluster(data, at: start), next > start else { break }
            let segment = mediaSegment(from: frames, sequenceNumber: sequence)
            segments.append(.init(outputOffset: outputOffset, length: segment.count,
                                  clusterOffset: start, sequence: sequence))
            outputOffset += segment.count
            sequence += 1
            clusterOffset = next
        }
        return StreamIndex(totalLength: outputOffset, initLength: initLength, segments: segments)
    }

    /// Read `[offset, offset+length)` of the remuxed output, regenerating only
    /// the segments that overlap the range. Deterministic — the regenerated
    /// bytes match what `buildStreamIndex` measured.
    public func readBytes(offset: Int, length: Int, index: StreamIndex) -> [UInt8] {
        let end = min(offset + length, index.totalLength)
        guard offset >= 0, offset < end else { return [] }
        var result: [UInt8] = []

        // Init-segment region.
        if offset < index.initLength {
            let initSegment = initializationSegment()
            result += Array(initSegment[offset..<min(end, index.initLength)])
        }

        // Overlapping media segments.
        for segment in index.segments {
            let segmentEnd = segment.outputOffset + segment.length
            guard segmentEnd > offset, segment.outputOffset < end else { continue }
            guard let (frames, _) = MatroskaFrameReader.readCluster(data, at: segment.clusterOffset) else { continue }
            let bytes = mediaSegment(from: frames, sequenceNumber: segment.sequence)
            let lo = max(offset, segment.outputOffset) - segment.outputOffset
            let hi = min(end, segmentEnd) - segment.outputOffset
            if lo < hi { result += Array(bytes[lo..<hi]) }
        }
        return result
    }

    /// Build one media segment from a batch of frames (e.g. one cluster).
    func mediaSegment(from frames: [MatroskaFrame], sequenceNumber: UInt32) -> [UInt8] {
        var framesByTrack: [UInt32: [MatroskaFrame]] = [:]
        for frame in frames {
            guard let id = trackIDByNumber[frame.trackNumber] else { continue }
            framesByTrack[id, default: []].append(frame)
        }

        var fragmentTracks: [FragmentedMP4Writer.FragmentTrack] = []
        for track in tracks {
            guard let trackFrames = framesByTrack[track.trackID], !trackFrames.isEmpty else { continue }
            let ordered = trackFrames.sorted { $0.timestampTicks < $1.timestampTicks }
            let samples = makeSamples(ordered)
            let base = UInt64(max(0, ordered.first?.timestampTicks ?? 0))
            fragmentTracks.append(.init(trackID: track.trackID, baseDecodeTime: base, samples: samples))
        }
        return writer.mediaSegment(sequenceNumber: sequenceNumber, tracks: fragmentTracks)
    }

    /// Per-sample durations from successive presentation timestamps. The last
    /// sample reuses the previous duration (no following frame to measure
    /// against). Frames are already in timestamp order.
    private func makeSamples(_ frames: [MatroskaFrame]) -> [FragmentedMP4Writer.Sample] {
        var samples: [FragmentedMP4Writer.Sample] = []
        samples.reserveCapacity(frames.count)
        for i in frames.indices {
            let duration: UInt32
            if i + 1 < frames.count {
                duration = UInt32(max(0, frames[i + 1].timestampTicks - frames[i].timestampTicks))
            } else {
                duration = samples.last?.duration ?? 0
            }
            samples.append(.init(data: frames[i].data, duration: duration, isKeyframe: frames[i].isKeyframe))
        }
        return samples
    }
}
