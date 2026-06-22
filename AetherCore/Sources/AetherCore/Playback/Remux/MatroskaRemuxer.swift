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

    private let source: any ByteSource
    private let firstClusterOffset: Int?
    /// Matroska track number → fMP4 track id.
    private let trackIDByNumber: [UInt64: UInt32]
    private let writer: FragmentedMP4Writer

    public init?(data: Data) {
        self.init(source: DataByteSource(data))
    }

    public init?(source: any ByteSource) {
        guard let segment = try? MatroskaDemuxer.probe(source) else { return nil }

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
        self.source = source
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
        let frames = MatroskaFrameReader.readAllFrames(source, from: start)
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
    ///
    /// Computes each segment's size **analytically from frame sizes**
    /// (`mediaSegmentByteSize`) rather than building the segment, so the pass
    /// reads only the cluster/block structure — not the gigabytes of sample
    /// data. This is what keeps first-play off a full-file copy.
    public func buildStreamIndex() -> StreamIndex {
        let initLength = initializationSegment().count
        var segments: [StreamIndex.Segment] = []
        var outputOffset = initLength
        var sequence: UInt32 = 1
        var clusterOffset = firstClusterOffset
        while let start = clusterOffset, start < source.count {
            guard let (frames, next) = MatroskaFrameReader.readClusterFrameInfo(source, at: start),
                  next > start else { break }
            // Group by track in the same order mediaSegment emits trafs (only
            // tracks with frames, in `tracks` order) so the size matches exactly.
            var byTrack: [UInt32: (count: Int, bytes: Int)] = [:]
            for frame in frames {
                guard let id = trackIDByNumber[frame.trackNumber] else { continue }
                var entry = byTrack[id] ?? (0, 0)
                entry.count += 1
                entry.bytes += frame.size
                byTrack[id] = entry
            }
            let perTrack = tracks.compactMap { byTrack[$0.trackID] }
                .map { (sampleCount: $0.count, dataBytes: $0.bytes) }
            let length = writer.mediaSegmentByteSize(perTrack)
            if !perTrack.isEmpty {
                segments.append(.init(outputOffset: outputOffset, length: length,
                                      clusterOffset: start, sequence: sequence))
                outputOffset += length
                sequence += 1
            }
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
            guard let (frames, _) = MatroskaFrameReader.readCluster(source, at: segment.clusterOffset) else { continue }
            let bytes = mediaSegment(from: frames, sequenceNumber: segment.sequence)
            let lo = max(offset, segment.outputOffset) - segment.outputOffset
            let hi = min(end, segmentEnd) - segment.outputOffset
            if lo < hi { result += Array(bytes[lo..<hi]) }
        }
        return result
    }

    /// Remux just the first `clusterLimit` clusters into a self-contained fMP4
    /// (init + that many media segments). For validation / quick previews
    /// without processing a whole multi-GB file.
    public func remuxPrefix(clusterLimit: Int) -> [UInt8] {
        var output = initializationSegment()
        guard let start = firstClusterOffset else { return output }
        var offset = start
        var sequence: UInt32 = 1
        var produced = 0
        while produced < clusterLimit, offset < source.count {
            guard let (frames, next) = MatroskaFrameReader.readCluster(source, at: offset), next > offset else { break }
            output += mediaSegment(from: frames, sequenceNumber: sequence)
            offset = next
            sequence += 1
            produced += 1
        }
        return output
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
            // Keep the frames in **decode (storage) order** — Matroska stores them
            // that way, and H.264/HEVC must be fed to the decoder in decode order.
            // Sorting by PTS (as we did before) scrambled B-frame order and the
            // decoder produced torn video. DTS is derived from the PTS set inside
            // makeSamples; the fragment's decode timeline starts at the min PTS.
            let samples = makeSamples(trackFrames)
            let base = UInt64(max(0, trackFrames.map(\.timestampTicks).min() ?? 0))
            fragmentTracks.append(.init(trackID: track.trackID, baseDecodeTime: base, samples: samples))
        }
        return writer.mediaSegment(sequenceNumber: sequenceNumber, tracks: fragmentTracks)
    }

    /// Build samples from decode-order frames, deriving the DTS timeline and the
    /// per-sample composition (PTS − DTS) offsets that B-frames require.
    ///
    /// DTS is the PTS set sorted ascending (a valid monotonic decode timeline
    /// with the same frame spacing); the composition offset reinstates each
    /// frame's actual presentation time. Durations are DTS deltas. The last
    /// sample reuses the previous duration (no following DTS to measure against).
    private func makeSamples(_ frames: [MatroskaFrame]) -> [FragmentedMP4Writer.Sample] {
        let pts = frames.map(\.timestampTicks)        // decode order
        let dts = pts.sorted()                         // monotonic decode timeline
        var samples: [FragmentedMP4Writer.Sample] = []
        samples.reserveCapacity(frames.count)
        for i in frames.indices {
            let duration: UInt32
            if i + 1 < dts.count {
                duration = UInt32(max(0, dts[i + 1] - dts[i]))
            } else {
                duration = samples.last?.duration ?? 0
            }
            let composition = Int32(clamping: pts[i] - dts[i])
            samples.append(.init(data: frames[i].data, duration: duration,
                                 isKeyframe: frames[i].isKeyframe, compositionOffset: composition))
        }
        return samples
    }
}
