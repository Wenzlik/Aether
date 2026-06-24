import Foundation

/// Drives the Tier 1 remux pipeline end to end (#476): probe a Matroska file,
/// then build a **progressive** MP4 (`moov` with full sample tables + one
/// `mdat`) AVPlayer can play and seek over the resource loader. Ties
/// `MatroskaDemuxer` + `MatroskaFrameReader` to `ProgressiveMP4Writer` /
/// `ProgressiveRemuxReader`.
///
/// `init?` fails (returns `nil`) when the file isn't Matroska or carries no
/// track the muxer can package (H.264/HEVC video + AAC audio today) — the caller
/// then falls back to another engine. Sample durations are derived from frame
/// timestamps; because the track timescale is set to the Matroska tick rate,
/// timestamps map across 1:1.
public struct MatroskaRemuxer {
    /// Tracks that will appear in the MP4 output (packageable ones only).
    public let tracks: [RemuxTrack]

    private let source: any ByteSource
    private let firstClusterOffset: Int?
    /// Matroska track number → fMP4 track id.
    private let trackIDByNumber: [UInt64: UInt32]
    /// Ticks per second of the Matroska timeline (= the video/movie timescale).
    /// Audio sample timestamps are converted from this into the audio track's
    /// sample-rate timescale.
    private let movieTimescale: UInt32

    /// Video + audio tracks, in file order — these drive the progressive sample
    /// tables and the mdat layout.
    private let mediaTracks: [RemuxTrack]
    /// Subtitle (WebVTT) tracks.
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
        // A/V track.
        guard !mediaTracks.isEmpty else { return nil }

        // (E-)AC-3 tracks carry no CodecPrivate: synthesise the dac3/dec3 config
        // and exact channel/rate/frame geometry from the first coded frame. If a
        // frame can't be read or the codec config isn't packageable (half-rate
        // E-AC-3, dependent substreams, …) bail the whole remux → VLCKit.
        for i in mediaTracks.indices
        where mediaTracks[i].kind == .audio
            && (mediaTracks[i].audioCodec == .ac3 || mediaTracks[i].audioCodec == .eac3) {
            let track = mediaTracks[i]
            guard let number = idByNumber.first(where: { $0.value == track.trackID })?.key,
                  let frame = Self.firstFrame(source, from: segment.firstClusterOffset, track: number),
                  let codec = track.audioCodec,
                  let parsed = AudioBitstreamConfig.parse(codec: codec, firstFrame: frame)
            else { return nil }
            mediaTracks[i] = track.settingAudioConfig(
                parsed.configBox, channels: parsed.channels,
                sampleRate: parsed.sampleRate, samplesPerFrame: parsed.samplesPerFrame)
        }

        self.tracks = mediaTracks + subtitleTracks
        self.mediaTracks = mediaTracks
        self.subtitleTracks = subtitleTracks
        self.subtitleTrackNumbers = subtitleNumbers
        self.source = source
        self.firstClusterOffset = segment.firstClusterOffset
        self.trackIDByNumber = idByNumber
        self.movieTimescale = timescale
        self.totalDurationTicks = Int64(segment.info.durationTicks ?? 0)
    }

    /// Read the first non-empty coded frame of `track` by scanning clusters from
    /// `firstClusterOffset` (bounded). Used to derive the (E-)AC-3 config, which
    /// the bitstream syncframe carries but MKV CodecPrivate does not.
    private static func firstFrame(_ source: any ByteSource, from firstClusterOffset: Int?,
                                   track: UInt64) -> [UInt8]? {
        guard var offset = firstClusterOffset else { return nil }
        for _ in 0..<32 {   // a frame appears within the first handful of clusters
            guard let (frames, next) = MatroskaFrameReader.readCluster(
                source, at: offset, trackFilter: [track]) else { return nil }
            if let frame = frames.first(where: { $0.trackNumber == track && !$0.data.isEmpty }) {
                return frame.data
            }
            guard next > offset else { return nil }
            offset = next
        }
        return nil
    }

    // MARK: - Progressive (non-fragmented) output

    /// Build a reader over a **progressive** MP4 remux (`moov` with full sample
    /// tables + one `mdat`). This is what AVPlayer seeks over the resource
    /// loader: progressive `stco`/`stss`/`stts` give an exact time→byte map (a
    /// fragmented MP4 has none AVPlayer will use, so scrubbing hangs). Does one
    /// metadata pass over the file (no payload copy) to build the tables; bytes
    /// are read on demand while playing.
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

    /// Number of audio samples per coded frame. AAC-LC is 1024 (the common case);
    /// HE-AAC/SBR is 2048 but is rare and still plays acceptably at 1024 spacing.
    private static let aacSamplesPerFrame: UInt32 = 1024

    /// Shape a media track's samples for the progressive sample tables. Video:
    /// DTS = sorted PTS (monotonic decode timeline), durations = DTS deltas,
    /// composition offset = PTS − DTS (B-frames). Audio: each AAC frame is 1024
    /// samples at the sample-rate timescale. Samples stay in source (decode)
    /// order — matching the mdat byte order and the source map.
    private func shapeMediaSamples(_ metas: [MatroskaFrameReader.SampleMeta], track: RemuxTrack)
        -> (samples: [ProgressiveMP4Writer.Sample], sourceMap: [(sourceOffset: Int, size: Int)]) {
        let sourceMap = metas.map { (sourceOffset: $0.sourceOffset, size: $0.size) }
        if track.kind == .audio {
            // Per-codec frame duration (AAC 1024, AC-3 1536, E-AC-3 numblks*256)
            // at the sample-rate timescale → audio stays locked to video.
            let perFrame = track.audioSamplesPerFrame
            let samples = metas.map {
                ProgressiveMP4Writer.Sample(size: $0.size, duration: perFrame,
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

    // MARK: - Subtitle cues (WebVTT, #476 P6)

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
}
