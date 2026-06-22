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
