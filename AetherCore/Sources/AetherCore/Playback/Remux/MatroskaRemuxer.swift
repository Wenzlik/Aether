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
    /// Ticks per second of the Matroska timeline (= the video/movie timescale).
    /// Audio sample timestamps are converted from this into the audio track's
    /// sample-rate timescale.
    private let movieTimescale: UInt32

    /// Video + audio tracks only — these drive the per-cluster media segments
    /// (and the analytic stream index). Subtitles are handled separately.
    private let mediaTracks: [RemuxTrack]
    /// Subtitle (WebVTT) tracks. Emitted as ONE eager media segment placed right
    /// after the init segment (their cues span the whole movie and the data is
    /// tiny), rather than fragmented per cluster — see `subtitleSegment()`.
    private let subtitleTracks: [RemuxTrack]
    /// Matroska track numbers of the subtitle tracks, for selective extraction.
    private let subtitleTrackNumbers: Set<UInt64>
    /// Total movie duration in Matroska ticks (= `movieTimescale` units) — the
    /// span the subtitle samples must tile. 0 if the container didn't state it.
    private let totalDurationTicks: Int64

    public init?(data: Data) {
        self.init(source: DataByteSource(data))
    }

    public init?(source: any ByteSource) {
        guard let segment = try? MatroskaDemuxer.probe(source) else { return nil }

        // Track timescale = ticks per second implied by the Matroska timestamp
        // scale (default 1 ms → 1000).
        let timescale = UInt32(max(1, 1_000_000_000 / segment.info.timestampScaleNs))

        var mediaTracks: [RemuxTrack] = []
        var subtitleTracks: [RemuxTrack] = []
        var subtitleNumbers: Set<UInt64> = []
        var idByNumber: [UInt64: UInt32] = [:]
        var nextID: UInt32 = 1
        for track in segment.tracks {
            switch track.type {
            case .video, .audio:
                // A real A/V track we can't package (E-AC-3, DTS, VC-1, …) means
                // remuxing would drop audio or video — worse than the fallback.
                // Bail so the whole file goes to VLCKit/server instead. (The
                // DetailView local path builds RemuxedLocalAsset directly without
                // a codec probe, so this is where that rule must hold.)
                guard let remux = RemuxTrack(matroska: track, trackID: nextID,
                                             timescaleTicksPerSecond: timescale) else { return nil }
                mediaTracks.append(remux)
                idByNumber[track.number] = nextID
                nextID += 1
            case .subtitle:
                // Carry SRT (S_TEXT/UTF8) as WebVTT (#476 P6). Unsupported subtitle
                // formats return nil → drop the track (don't bail the whole remux).
                guard let remux = RemuxTrack(matroska: track, trackID: nextID,
                                             timescaleTicksPerSecond: timescale) else { continue }
                subtitleTracks.append(remux)
                subtitleNumbers.insert(track.number)
                idByNumber[track.number] = nextID
                nextID += 1
            case .other:
                continue
            }
        }
        // A subtitle-only file is nothing to remux — there must be at least one
        // A/V track (the per-cluster media path requires it).
        guard !mediaTracks.isEmpty else { return nil }

        let allTracks = mediaTracks + subtitleTracks
        self.tracks = allTracks
        self.mediaTracks = mediaTracks
        self.subtitleTracks = subtitleTracks
        self.subtitleTrackNumbers = subtitleNumbers
        self.source = source
        self.firstClusterOffset = segment.firstClusterOffset
        self.trackIDByNumber = idByNumber
        self.movieTimescale = timescale
        self.totalDurationTicks = Int64(segment.info.durationTicks ?? 0)
        // Movie timescale is 1000 (see mvhd); declare the total duration in mehd
        // so a streamed fragmented MP4 reports the real length, not a guess.
        let durationTicks = UInt32(clamping: Int((segment.info.durationSeconds ?? 0) * 1000))
        self.writer = FragmentedMP4Writer(tracks: allTracks, movieDurationTicks: durationTicks)
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
        let subtitle = subtitleSegment()
        output += subtitle
        guard let start = firstClusterOffset else { return output }
        let frames = MatroskaFrameReader.readAllFrames(source, from: start)
        output += mediaSegment(from: frames, sequenceNumber: subtitle.isEmpty ? 1 : 2)
        return output
    }

    // MARK: - Subtitle segment (WebVTT, #476 P6)

    /// Build the single fMP4 media segment that carries every subtitle track's
    /// cues for the whole movie. Returns `[]` when there are no subtitle tracks
    /// (or no cues). Placed right after the init segment by the streaming and
    /// whole-file paths — subtitle data is small, so it's materialised eagerly
    /// rather than fragmented per cluster (which would break the analytic stream
    /// index, whose sizes come from frame bytes alone — a WebVTT sample's size
    /// depends on its cue text and on gap-filler samples).
    func subtitleSegment() -> [UInt8] {
        guard !subtitleTracks.isEmpty, let start = firstClusterOffset else { return [] }
        let frames = MatroskaFrameReader.readSubtitleFrames(source, from: start,
                                                            trackNumbers: subtitleTrackNumbers)
        guard !frames.isEmpty else { return [] }

        var fragmentTracks: [FragmentedMP4Writer.FragmentTrack] = []
        for track in subtitleTracks {
            let trackFrames = frames.filter { trackIDByNumber[$0.trackNumber] == track.trackID }
            let cues = makeCues(trackFrames)
            guard !cues.isEmpty else { continue }
            // Tile to the stated movie duration, or — if unknown — to just past
            // the last cue so the samples still form a complete timeline.
            let lastEnd = cues.map { $0.startTicks + $0.durationTicks }.max() ?? 0
            let span = totalDurationTicks > lastEnd ? totalDurationTicks : lastEnd
            let samples = WebVTTSampleBuilder.samples(cues: cues, totalDurationTicks: span)
            guard !samples.isEmpty else { continue }
            fragmentTracks.append(.init(trackID: track.trackID, baseDecodeTime: 0, samples: samples))
        }
        guard !fragmentTracks.isEmpty else { return [] }
        return writer.mediaSegment(sequenceNumber: 1, tracks: fragmentTracks)
    }

    /// Default on-screen time for a cue with no `BlockDuration` and no following
    /// cue to bound it (3 s, in movie ticks).
    private var defaultCueDurationTicks: Int64 { 3 * Int64(movieTimescale) }

    /// Convert a subtitle track's Matroska frames into WebVTT cues: decode the
    /// SRT text, clean it for WebVTT, and resolve each cue's duration from
    /// `BlockDuration`, else the gap to the next cue, else a 3 s default.
    private func makeCues(_ frames: [MatroskaFrame]) -> [WebVTTSampleBuilder.Cue] {
        let sorted = frames.sorted { $0.timestampTicks < $1.timestampTicks }
        var cues: [WebVTTSampleBuilder.Cue] = []
        for (i, frame) in sorted.enumerated() {
            let text = WebVTTConverter.payload(fromSRT: String(decoding: frame.data, as: UTF8.self))
            guard !text.isEmpty else { continue }
            let duration: Int64
            if let stated = frame.durationTicks, stated > 0 {
                duration = stated
            } else if i + 1 < sorted.count {
                duration = max(1, sorted[i + 1].timestampTicks - frame.timestampTicks)
            } else {
                duration = defaultCueDurationTicks
            }
            cues.append(.init(startTicks: frame.timestampTicks, durationTicks: duration, payload: text))
        }
        return cues
    }

    // MARK: - Progressive (non-fragmented) output

    /// Build a reader over a **progressive** MP4 remux (`moov` with full sample
    /// tables + one `mdat`). This is the path AVPlayer actually seeks: a
    /// fragmented MP4 over the resource loader has no time→byte map AVPlayer will
    /// use, so scrubbing hangs; progressive `stco`/`stss`/`stts` give exact byte
    /// offsets for any seek time. Does one metadata pass over the file (no
    /// payload copy) to build the tables; bytes are read on demand while playing.
    public func progressiveReader() -> ProgressiveRemuxReader {
        let metas = firstClusterOffset.map { MatroskaFrameReader.readSampleIndex(source, from: $0) } ?? []
        var metasByTrack: [UInt64: [MatroskaFrameReader.SampleMeta]] = [:]
        for meta in metas { metasByTrack[meta.trackNumber, default: []].append(meta) }

        var writerTracks: [ProgressiveMP4Writer.Track] = []
        // Per writer track, the source mapping: A/V sample (sourceOffset, size)
        // ranges, or the generated subtitle bytes. Parallel to `writerTracks`.
        var sourceInfo: [(av: [(sourceOffset: Int, size: Int)]?, inline: [UInt8]?)] = []

        // Video + audio, in mediaTracks order.
        for track in mediaTracks {
            guard let number = trackIDByNumber.first(where: { $0.value == track.trackID })?.key,
                  let trackMetas = metasByTrack[number], !trackMetas.isEmpty else { continue }
            let (samples, map) = shapeMediaSamples(trackMetas, track: track)
            writerTracks.append(.init(track: track, samples: samples))
            sourceInfo.append((av: map, inline: nil))
        }

        // Subtitle tracks: cues need their text, so read the (tiny) subtitle
        // payloads and build WebVTT samples held inline.
        if !subtitleTracks.isEmpty, let start = firstClusterOffset {
            let frames = MatroskaFrameReader.readSubtitleFrames(source, from: start, trackNumbers: subtitleTrackNumbers)
            for track in subtitleTracks {
                let trackFrames = frames.filter { trackIDByNumber[$0.trackNumber] == track.trackID }
                let cues = makeCues(trackFrames)
                guard !cues.isEmpty else { continue }
                let lastEnd = cues.map { $0.startTicks + $0.durationTicks }.max() ?? 0
                let span = totalDurationTicks > lastEnd ? totalDurationTicks : lastEnd
                let builderSamples = WebVTTSampleBuilder.samples(cues: cues, totalDurationTicks: span)
                guard !builderSamples.isEmpty else { continue }
                let progSamples = builderSamples.map {
                    ProgressiveMP4Writer.Sample(size: $0.data.count, duration: $0.duration,
                                                compositionOffset: 0, isKeyframe: true)
                }
                writerTracks.append(.init(track: track, samples: progSamples))
                sourceInfo.append((av: nil, inline: builderSamples.flatMap { $0.data }))
            }
        }

        let durationMs = totalDurationTicks > 0
            ? UInt32(clamping: Int(totalDurationTicks) * 1000 / Int(max(1, movieTimescale))) : 0
        let writer = ProgressiveMP4Writer(tracks: writerTracks, movieDurationMs: durationMs)
        let initSegment = writer.initSegment()
        let offsets = writer.trackDataOffsets()

        var regions: [ProgressiveRemuxReader.Region] = []
        for (index, info) in sourceInfo.enumerated() {
            let outputStart = offsets[index]
            if let inline = info.inline {
                regions.append(.init(outputStart: outputStart, size: inline.count,
                                     avSamples: nil, inlineData: inline))
            } else if let map = info.av {
                var avSamples: [ProgressiveRemuxReader.AVSample] = []
                avSamples.reserveCapacity(map.count)
                var cum = 0
                for sample in map {
                    avSamples.append(.init(cumOffset: cum, sourceOffset: sample.sourceOffset, size: sample.size))
                    cum += sample.size
                }
                regions.append(.init(outputStart: outputStart, size: cum,
                                     avSamples: avSamples, inlineData: nil))
            }
        }
        return ProgressiveRemuxReader(source: source, initSegment: initSegment,
                                      regions: regions, contentLength: writer.totalLength)
    }

    /// Shape a media track's samples for the progressive sample tables. Video:
    /// DTS = sorted PTS (monotonic decode timeline), durations = DTS deltas,
    /// composition offset = PTS − DTS (B-frames). Audio: each AAC frame is 1024
    /// samples at the sample-rate timescale. Samples stay in source (decode)
    /// order — matching the mdat byte order and the source map.
    private func shapeMediaSamples(_ metas: [MatroskaFrameReader.SampleMeta], track: RemuxTrack)
        -> (samples: [ProgressiveMP4Writer.Sample], sourceMap: [(sourceOffset: Int, size: Int)]) {
        let sourceMap = metas.map { (sourceOffset: $0.sourceOffset, size: $0.size) }
        if track.kind == .audio {
            let samples = metas.map {
                ProgressiveMP4Writer.Sample(size: $0.size, duration: Self.aacSamplesPerFrame,
                                            compositionOffset: 0, isKeyframe: true)
            }
            return (samples, sourceMap)
        }
        let pts = metas.map(\.timestampTicks)
        let dts = pts.sorted()
        var samples: [ProgressiveMP4Writer.Sample] = []
        samples.reserveCapacity(metas.count)
        for i in metas.indices {
            let duration: UInt32
            if i + 1 < dts.count {
                duration = UInt32(max(0, dts[i + 1] - dts[i]))
            } else {
                duration = samples.last?.duration ?? 1
            }
            samples.append(.init(size: metas[i].size, duration: duration,
                                 compositionOffset: Int32(clamping: pts[i] - dts[i]),
                                 isKeyframe: metas[i].isKeyframe))
        }
        return (samples, sourceMap)
    }

    // MARK: - Range-addressable streaming

    /// A map of the remuxed output's byte layout, built in one pass over the
    /// source. Lets a server (the SMB range proxy / an AVFoundation resource
    /// loader) answer arbitrary byte-range requests **without** holding the whole
    /// remuxed file in memory — only segment sizes + their source cluster offset
    /// are kept; the bytes are regenerated on demand from the cluster.
    public struct StreamIndex: Sendable {
        public let totalLength: Int
        /// The materialised init segment (`ftyp`+`moov`+`sidx`). Stored rather
        /// than recomputed because it carries the `sidx` seek index, which depends
        /// on the full fragment layout discovered during the index pass.
        let initSegment: [UInt8]
        var initLength: Int { initSegment.count }
        /// The fully-materialised subtitle media segment (WebVTT), served from the
        /// region directly after the init segment. Empty when there are no
        /// subtitles. The A/V `segments` below start after it.
        let subtitleSegment: [UInt8]
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
        let subtitle = subtitleSegment()

        // Pass over the clusters once: record each A/V fragment's analytic size,
        // source cluster, and base timestamp (the last is what lets us derive
        // per-fragment durations for the sidx).
        struct RawSegment { let clusterOffset: Int; let length: Int; let timestamp: Int64 }
        var raw: [RawSegment] = []
        var clusterOffset = firstClusterOffset
        while let start = clusterOffset, start < source.count {
            guard let (frames, timestamp, next) = MatroskaFrameReader.readClusterFrameInfo(source, at: start),
                  next > start else { break }
            // Group by track in the same order mediaSegment emits trafs (only A/V
            // tracks with frames, in `mediaTracks` order) so the size matches
            // exactly. Subtitle frames live in the eager segment, not here.
            var byTrack: [UInt32: (count: Int, bytes: Int)] = [:]
            for frame in frames {
                guard let id = trackIDByNumber[frame.trackNumber] else { continue }
                var entry = byTrack[id] ?? (0, 0)
                entry.count += 1
                entry.bytes += frame.size
                byTrack[id] = entry
            }
            let perTrack = mediaTracks.compactMap { byTrack[$0.trackID] }
                .map { (sampleCount: $0.count, dataBytes: $0.bytes) }
            if !perTrack.isEmpty {
                raw.append(.init(clusterOffset: start,
                                 length: writer.mediaSegmentByteSize(perTrack),
                                 timestamp: timestamp))
            }
            clusterOffset = next
        }

        // sidx (seek index) over the video track: each A/V fragment's size + its
        // duration (gap to the next fragment's timestamp; the last runs to the
        // movie end). first_offset skips the eager subtitle segment.
        let videoTrack = mediaTracks.first { $0.kind == .video }
        let initSeg: [UInt8]
        if let videoTrack, !raw.isEmpty {
            let entries = raw.indices.map { i -> FragmentedMP4Writer.SidxEntry in
                let next = i + 1 < raw.count ? raw[i + 1].timestamp : max(raw[i].timestamp + 1, totalDurationTicks)
                return .init(size: raw[i].length, durationTicks: Int(max(1, next - raw[i].timestamp)))
            }
            let sidxBox = writer.sidx(referenceID: videoTrack.trackID, timescale: movieTimescale,
                                      earliestPresentationTime: UInt64(max(0, raw.first?.timestamp ?? 0)),
                                      firstOffset: UInt64(subtitle.count), entries: entries)
            initSeg = writer.initializationSegment(appending: sidxBox)
        } else {
            initSeg = initializationSegment()
        }

        // Assign output offsets now the init-segment size (with sidx) is known.
        var segments: [StreamIndex.Segment] = []
        var outputOffset = initSeg.count + subtitle.count   // A/V follows init + subtitle
        var sequence: UInt32 = subtitle.isEmpty ? 1 : 2      // subtitle segment is #1
        for r in raw {
            segments.append(.init(outputOffset: outputOffset, length: r.length,
                                  clusterOffset: r.clusterOffset, sequence: sequence))
            outputOffset += r.length
            sequence += 1
        }
        return StreamIndex(totalLength: outputOffset, initSegment: initSeg,
                           subtitleSegment: subtitle, segments: segments)
    }

    /// Read `[offset, offset+length)` of the remuxed output, regenerating only
    /// the segments that overlap the range. Deterministic — the regenerated
    /// bytes match what `buildStreamIndex` measured.
    public func readBytes(offset: Int, length: Int, index: StreamIndex) -> [UInt8] {
        let end = min(offset + length, index.totalLength)
        guard offset >= 0, offset < end else { return [] }
        var result: [UInt8] = []

        // Init-segment region (ftyp+moov+sidx, materialised in the index).
        if offset < index.initLength {
            result += Array(index.initSegment[offset..<min(end, index.initLength)])
        }

        // Subtitle-segment region (immediately after init).
        let subStart = index.initLength
        let subEnd = subStart + index.subtitleSegment.count
        if offset < subEnd, end > subStart {
            let lo = max(offset, subStart) - subStart
            let hi = min(end, subEnd) - subStart
            if lo < hi { result += Array(index.subtitleSegment[lo..<hi]) }
        }

        // Overlapping media segments.
        for segment in index.segments {
            let segmentEnd = segment.outputOffset + segment.length
            guard segmentEnd > offset, segment.outputOffset < end else { continue }
            let bytes = segmentData(segment)
            let lo = max(offset, segment.outputOffset) - segment.outputOffset
            let hi = min(end, segmentEnd) - segment.outputOffset
            if lo < hi { result += Array(bytes[lo..<hi]) }
        }
        return result
    }

    /// Regenerate one media segment's bytes from its source cluster. Deterministic
    /// (matches the size `buildStreamIndex` recorded). `RemuxByteReader` caches
    /// the result so a segment isn't rebuilt for every overlapping byte-range
    /// request.
    func segmentData(_ segment: StreamIndex.Segment) -> [UInt8] {
        guard let (frames, _) = MatroskaFrameReader.readCluster(source, at: segment.clusterOffset) else { return [] }
        return mediaSegment(from: frames, sequenceNumber: segment.sequence)
    }

    /// Remux just the first `clusterLimit` clusters into a self-contained fMP4
    /// (init + that many media segments). For validation / quick previews
    /// without processing a whole multi-GB file.
    public func remuxPrefix(clusterLimit: Int) -> [UInt8] {
        var output = initializationSegment()
        let subtitle = subtitleSegment()
        output += subtitle
        guard let start = firstClusterOffset else { return output }
        var offset = start
        var sequence: UInt32 = subtitle.isEmpty ? 1 : 2
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
        for track in mediaTracks {
            guard let trackFrames = framesByTrack[track.trackID], !trackFrames.isEmpty else { continue }
            // Frames stay in decode (storage) order — H.264/HEVC must be fed in
            // decode order, and DTS/durations are derived per track below.
            let (samples, base) = makeSamples(trackFrames, track: track)
            fragmentTracks.append(.init(trackID: track.trackID, baseDecodeTime: base, samples: samples))
        }
        return writer.mediaSegment(sequenceNumber: sequenceNumber, tracks: fragmentTracks)
    }

    /// Number of audio samples per coded frame. AAC-LC is 1024 (the common case);
    /// HE-AAC/SBR is 2048 but is rare and still plays acceptably at 1024 spacing.
    private static let aacSamplesPerFrame: UInt32 = 1024

    /// Build samples + the fragment's `baseMediaDecodeTime`, per track kind.
    ///
    /// **Video**: keep decode order; DTS is the PTS set sorted ascending (a valid
    /// monotonic decode timeline), durations are DTS deltas, and the composition
    /// offset (PTS − DTS) reinstates presentation order for B-frames.
    ///
    /// **Audio**: Matroska laces several AAC frames into one block sharing a
    /// single timestamp, so PTS deltas are 0 — useless for durations. Instead use
    /// the exact AAC frame size (1024 samples) at the sample-rate timescale, which
    /// gives a continuous, drift-free timeline. Base = first frame's PTS converted
    /// from the movie timescale into the audio sample-rate timescale.
    private func makeSamples(_ frames: [MatroskaFrame], track: RemuxTrack) -> (samples: [FragmentedMP4Writer.Sample], baseDecodeTime: UInt64) {
        if track.kind == .audio {
            let minPTS = frames.map(\.timestampTicks).min() ?? 0
            let base = UInt64(max(0, minPTS)) * UInt64(track.timescale) / UInt64(max(1, movieTimescale))
            let samples = frames.map {
                FragmentedMP4Writer.Sample(data: $0.data, duration: Self.aacSamplesPerFrame,
                                           isKeyframe: true, compositionOffset: 0)
            }
            return (samples, base)
        }

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
        return (samples, UInt64(max(0, dts.first ?? 0)))
    }
}
