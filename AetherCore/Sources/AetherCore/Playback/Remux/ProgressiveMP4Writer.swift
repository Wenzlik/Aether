import Foundation

/// Writes a **progressive** (non-fragmented) MP4 from remuxed Matroska samples
/// (#476 Tier 1): one `moov` with complete `stbl` sample tables for every track,
/// followed by a single `mdat` holding all sample bytes in track order
/// (video, then audio, then subtitle).
///
/// Why progressive rather than fragmented: AVPlayer served via an
/// `AVAssetResourceLoader` won't reliably seek a fragmented MP4 (it has no
/// time→byte map it trusts, so a scrub hangs — the scrubber moves but the frame
/// never loads). A progressive `moov` carries exact per-sample byte offsets
/// (`stco`/`co64`) + sync-sample (`stss`) and time (`stts`) tables, so AVPlayer
/// can translate any seek time into a precise byte range and request it.
///
/// Codec samples pass through unchanged (H.264/HEVC length-prefixed NALs match
/// `avcC`; AAC raw frames; WebVTT cue boxes), so this only assembles the box
/// structure — no transcoding. `mdat` payload bytes aren't held here: the muxer
/// streams them on demand from the source file via the sample index.
struct ProgressiveMP4Writer {
    /// One sample's table metadata. The bytes live in the source file (A/V) or
    /// are generated (subtitle); this carries only what the tables need.
    struct Sample: Sendable, Equatable {
        let size: Int
        /// Duration in the track timescale (next DTS − this DTS for video, the
        /// AAC frame length for audio, the cue span for subtitles).
        let duration: UInt32
        /// PTS − DTS, for B-frame reordering (video). 0 otherwise.
        let compositionOffset: Int32
        let isKeyframe: Bool
    }

    struct Track: Sendable {
        let track: RemuxTrack
        let samples: [Sample]
        var dataBytes: Int { samples.reduce(0) { $0 + $1.size } }
    }

    let tracks: [Track]
    /// Total movie duration in the movie timescale (1000).
    let movieDurationMs: UInt32

    init(tracks: [Track], movieDurationMs: UInt32 = 0) {
        self.tracks = tracks
        self.movieDurationMs = movieDurationMs
    }

    /// Total `mdat` payload (all sample bytes across all tracks).
    var mdatPayloadSize: Int { tracks.reduce(0) { $0 + $1.dataBytes } }

    /// Byte offset where each track's contiguous run of samples begins in the
    /// output (absolute). Index matches `tracks`. Valid once the init segment is
    /// built (depends on its size).
    func trackDataOffsets() -> [Int] {
        let header = ftypAndMoovAndMdatHeaderSize()
        var offsets: [Int] = []
        var cursor = header
        for track in tracks {
            offsets.append(cursor)
            cursor += track.dataBytes
        }
        return offsets
    }

    /// Total output length: init (ftyp+moov+mdat header) + all sample bytes.
    var totalLength: Int { ftypAndMoovAndMdatHeaderSize() + mdatPayloadSize }

    /// `ftyp` + `moov` + the `mdat` box header (a 64-bit `largesize` box, since
    /// the payload can exceed 4 GB). The sample bytes follow, served separately.
    func initSegment() -> [UInt8] {
        MP4Box.ftyp() + moov(chunkOffsets: trackDataOffsets()) + mdatHeader()
    }

    // MARK: - Sizing

    /// Size of everything before the `mdat` payload. `co64` entries are a fixed 8
    /// bytes regardless of value, so the moov size doesn't depend on the offsets
    /// themselves — measuring it with zero offsets gives the real size, breaking
    /// the moov-size ⇄ chunk-offset circular dependency.
    private func ftypAndMoovAndMdatHeaderSize() -> Int {
        MP4Box.ftyp().count + moov(chunkOffsets: tracks.map { _ in 0 }).count + mdatHeader().count
    }

    /// The `mdat` box header: a normal 8-byte header when the box fits in 32
    /// bits, else a 64-bit `largesize` header (`size=1`) for >4 GB payloads.
    private func mdatHeader() -> [UInt8] {
        var w = MP4ByteWriter()
        if mdatPayloadSize + 8 <= 0xFFFF_FFFF {
            w.u32(UInt32(mdatPayloadSize + 8))
            w.fourCC("mdat")
        } else {
            w.u32(1)                              // size = 1 → largesize follows
            w.fourCC("mdat")
            w.u64(UInt64(mdatPayloadSize + 16))   // largesize includes the 16-byte header
        }
        return w.bytes
    }

    // MARK: - moov

    private func moov(chunkOffsets: [Int]) -> [UInt8] {
        var children: [[UInt8]] = [mvhd()]
        for (index, track) in tracks.enumerated() {
            children.append(trak(track, chunkOffset: chunkOffsets[index]))
        }
        return MP4Box.container("moov", children)
    }

    private func mvhd() -> [UInt8] {
        var w = MP4ByteWriter()
        w.u32(0); w.u32(0)            // creation / modification
        w.u32(1000)                  // movie timescale
        w.u32(movieDurationMs)        // duration
        w.u32(0x0001_0000)           // rate 1.0
        w.u16(0x0100)                // volume
        w.u16(0); w.u32(0); w.u32(0) // reserved
        appendIdentityMatrix(&w)
        for _ in 0..<6 { w.u32(0) }   // pre_defined
        w.u32(UInt32(tracks.count) + 1)   // next_track_ID
        return MP4Box.fullBox("mvhd", version: 0, flags: 0, w.bytes)
    }

    private func trak(_ track: Track, chunkOffset: Int) -> [UInt8] {
        MP4Box.container("trak", [tkhd(track.track), mdia(track, chunkOffset: chunkOffset)])
    }

    private func tkhd(_ track: RemuxTrack) -> [UInt8] {
        var w = MP4ByteWriter()
        w.u32(0); w.u32(0)           // creation / modification
        w.u32(track.trackID)
        w.u32(0)                     // reserved
        w.u32(movieDurationMs)        // duration (movie timescale)
        w.u32(0); w.u32(0)           // reserved
        w.u16(0)                     // layer
        let alternateGroup: UInt16
        switch track.kind {
        case .video:    alternateGroup = 0
        case .audio:    alternateGroup = 1
        case .subtitle: alternateGroup = 2
        }
        w.u16(alternateGroup)
        w.u16(track.kind == .audio ? 0x0100 : 0)   // volume
        w.u16(0)                     // reserved
        appendIdentityMatrix(&w)
        w.u32(UInt32(track.width) << 16)
        w.u32(UInt32(track.height) << 16)
        return MP4Box.fullBox("tkhd", version: 0, flags: 0x0000_07, w.bytes)
    }

    private func mdia(_ track: Track, chunkOffset: Int) -> [UInt8] {
        MP4Box.container("mdia", [mdhd(track), hdlr(track.track), minf(track, chunkOffset: chunkOffset)])
    }

    private func mdhd(_ track: Track) -> [UInt8] {
        let durationTicks = track.samples.reduce(0) { $0 + UInt64($1.duration) }
        var w = MP4ByteWriter()
        w.u32(0); w.u32(0)
        w.u32(track.track.timescale)
        w.u32(UInt32(clamping: durationTicks))
        w.u16(packedLanguage(track.track.language))
        w.u16(0)
        return MP4Box.fullBox("mdhd", version: 0, flags: 0, w.bytes)
    }

    private func hdlr(_ track: RemuxTrack) -> [UInt8] {
        let handlerType: String
        switch track.kind {
        case .video:    handlerType = "vide"
        case .audio:    handlerType = "soun"
        case .subtitle: handlerType = "text"
        }
        var w = MP4ByteWriter()
        w.u32(0)
        w.fourCC(handlerType)
        w.u32(0); w.u32(0); w.u32(0)
        w.append(Array("Aether\u{0}".utf8))
        return MP4Box.fullBox("hdlr", version: 0, flags: 0, w.bytes)
    }

    private func minf(_ track: Track, chunkOffset: Int) -> [UInt8] {
        let header: [UInt8]
        switch track.track.kind {
        case .video:    header = vmhd()
        case .audio:    header = smhd()
        case .subtitle: header = MP4Box.fullBox("nmhd", version: 0, flags: 0, [])
        }
        return MP4Box.container("minf", [header, dinf(), stbl(track, chunkOffset: chunkOffset)])
    }

    private func vmhd() -> [UInt8] {
        var w = MP4ByteWriter()
        w.u16(0); w.u16(0); w.u16(0); w.u16(0)
        return MP4Box.fullBox("vmhd", version: 0, flags: 1, w.bytes)
    }

    private func smhd() -> [UInt8] {
        var w = MP4ByteWriter()
        w.u16(0); w.u16(0)
        return MP4Box.fullBox("smhd", version: 0, flags: 0, w.bytes)
    }

    private func dinf() -> [UInt8] {
        let url = MP4Box.fullBox("url ", version: 0, flags: 0x0000_01, [])
        var dref = MP4ByteWriter()
        dref.u32(1)
        dref.append(url)
        return MP4Box.container("dinf", [MP4Box.fullBox("dref", version: 0, flags: 0, dref.bytes)])
    }

    // MARK: - stbl (the sample tables that make seeking work)

    private func stbl(_ track: Track, chunkOffset: Int) -> [UInt8] {
        var children: [[UInt8]] = [stsd(track.track), stts(track.samples)]
        if let ctts = ctts(track.samples) { children.append(ctts) }
        if let stss = stss(track.samples) { children.append(stss) }
        children.append(stsc(sampleCount: track.samples.count))
        children.append(stsz(track.samples))
        children.append(co64(chunkOffset))
        return MP4Box.container("stbl", children)
    }

    /// time-to-sample, run-length encoded (count, delta).
    private func stts(_ samples: [Sample]) -> [UInt8] {
        var runs: [(count: UInt32, delta: UInt32)] = []
        for s in samples {
            if var last = runs.last, last.delta == s.duration {
                last.count += 1; runs[runs.count - 1] = last
            } else {
                runs.append((1, s.duration))
            }
        }
        var w = MP4ByteWriter()
        w.u32(UInt32(runs.count))
        for run in runs { w.u32(run.count); w.u32(run.delta) }
        return MP4Box.fullBox("stts", version: 0, flags: 0, w.bytes)
    }

    /// composition time-to-sample (PTS − DTS), version 1 (signed). Omitted when
    /// no sample is reordered (all offsets 0).
    private func ctts(_ samples: [Sample]) -> [UInt8]? {
        guard samples.contains(where: { $0.compositionOffset != 0 }) else { return nil }
        var runs: [(count: UInt32, offset: Int32)] = []
        for s in samples {
            if var last = runs.last, last.offset == s.compositionOffset {
                last.count += 1; runs[runs.count - 1] = last
            } else {
                runs.append((1, s.compositionOffset))
            }
        }
        var w = MP4ByteWriter()
        w.u32(UInt32(runs.count))
        for run in runs { w.u32(run.count); w.i32(run.offset) }
        return MP4Box.fullBox("ctts", version: 1, flags: 0, w.bytes)
    }

    /// sync-sample table: the 1-based indices of keyframes. Omitted when every
    /// sample is a sync sample (the default AVFoundation assumes — e.g. audio).
    private func stss(_ samples: [Sample]) -> [UInt8]? {
        let syncIndices = samples.indices.filter { samples[$0].isKeyframe }.map { UInt32($0 + 1) }
        guard !syncIndices.isEmpty, syncIndices.count != samples.count else { return nil }
        var w = MP4ByteWriter()
        w.u32(UInt32(syncIndices.count))
        for i in syncIndices { w.u32(i) }
        return MP4Box.fullBox("stss", version: 0, flags: 0, w.bytes)
    }

    /// sample-to-chunk: a single chunk holding all of the track's samples (the
    /// whole track is one contiguous run in `mdat`).
    private func stsc(sampleCount: Int) -> [UInt8] {
        var w = MP4ByteWriter()
        w.u32(1)                          // entry_count
        w.u32(1)                          // first_chunk
        w.u32(UInt32(sampleCount))        // samples_per_chunk (one chunk holds them all)
        w.u32(1)                          // sample_description_index
        return MP4Box.fullBox("stsc", version: 0, flags: 0, w.bytes)
    }

    private func stsz(_ samples: [Sample]) -> [UInt8] {
        var w = MP4ByteWriter()
        w.u32(0)                          // sample_size 0 → sizes follow
        w.u32(UInt32(samples.count))
        for s in samples { w.u32(UInt32(clamping: s.size)) }
        return MP4Box.fullBox("stsz", version: 0, flags: 0, w.bytes)
    }

    private func co64(_ chunkOffset: Int) -> [UInt8] {
        var w = MP4ByteWriter()
        w.u32(1)                          // entry_count
        w.u64(UInt64(chunkOffset))
        return MP4Box.fullBox("co64", version: 0, flags: 0, w.bytes)
    }

    // MARK: - Sample descriptions

    private func stsd(_ track: RemuxTrack) -> [UInt8] {
        var w = MP4ByteWriter()
        w.u32(1)
        w.append(sampleEntry(track))
        return MP4Box.fullBox("stsd", version: 0, flags: 0, w.bytes)
    }

    private func sampleEntry(_ track: RemuxTrack) -> [UInt8] {
        switch track.kind {
        case .video:    return visualSampleEntry(track)
        case .audio:    return audioSampleEntry(track)
        case .subtitle: return webVTTSampleEntry()
        }
    }

    private func visualSampleEntry(_ track: RemuxTrack) -> [UInt8] {
        let type = track.videoCodec == .hevc ? "hvc1" : "avc1"
        let configType = track.videoCodec == .hevc ? "hvcC" : "avcC"
        var w = MP4ByteWriter()
        for _ in 0..<6 { w.u8(0) }
        w.u16(1)
        w.u16(0); w.u16(0)
        w.u32(0); w.u32(0); w.u32(0)
        w.u16(track.width); w.u16(track.height)
        w.u32(0x0048_0000); w.u32(0x0048_0000)
        w.u32(0)
        w.u16(1)
        for _ in 0..<32 { w.u8(0) }
        w.u16(0x0018)
        w.i16(-1)
        w.append(MP4Box.box(configType, track.codecConfig))
        return MP4Box.box(type, w.bytes)
    }

    private func audioSampleEntry(_ track: RemuxTrack) -> [UInt8] {
        var w = MP4ByteWriter()
        for _ in 0..<6 { w.u8(0) }
        w.u16(1)
        w.u32(0); w.u32(0)
        w.u16(track.channels)
        w.u16(16)
        w.u16(0); w.u16(0)
        w.u32(track.sampleRate << 16)
        switch track.audioCodec {
        case .ac3:
            // ETSI TS 102 366 Annex F.4: 'ac-3' sample entry + 'dac3' config.
            w.append(MP4Box.box("dac3", track.codecConfig))
            return MP4Box.box("ac-3", w.bytes)
        case .eac3:
            // Annex F.6: 'ec-3' sample entry + 'dec3' config.
            w.append(MP4Box.box("dec3", track.codecConfig))
            return MP4Box.box("ec-3", w.bytes)
        default:
            w.append(esds(asc: track.codecConfig, esID: UInt16(truncatingIfNeeded: track.trackID)))
            return MP4Box.box("mp4a", w.bytes)
        }
    }

    private func webVTTSampleEntry() -> [UInt8] {
        var w = MP4ByteWriter()
        for _ in 0..<6 { w.u8(0) }
        w.u16(1)
        w.append(MP4Box.box("vttC", Array("WEBVTT".utf8)))
        return MP4Box.box("wvtt", w.bytes)
    }

    private func esds(asc: [UInt8], esID: UInt16) -> [UInt8] {
        func descriptor(_ tag: UInt8, _ payload: [UInt8]) -> [UInt8] {
            [tag, 0x80, 0x80, 0x80, UInt8(payload.count)] + payload
        }
        let dsi = descriptor(0x05, asc)
        let dcd = descriptor(0x04, [0x40, 0x15] + [UInt8](repeating: 0, count: 11) + dsi)
        let sl = descriptor(0x06, [0x02])
        let es = descriptor(0x03, [UInt8(esID >> 8), UInt8(esID & 0xFF), 0x00] + dcd + sl)
        return MP4Box.fullBox("esds", version: 0, flags: 0, es)
    }

    // MARK: - Helpers

    private func appendIdentityMatrix(_ w: inout MP4ByteWriter) {
        let m: [UInt32] = [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000]
        for v in m { w.u32(v) }
    }

    private func packedLanguage(_ code: String?) -> UInt16 {
        let lang = (code?.count == 3 ? code! : "und").lowercased()
        let letters = Array(lang.utf8)
        let a = UInt16(letters[0]) - 0x60
        let b = UInt16(letters[1]) - 0x60
        let c = UInt16(letters[2]) - 0x60
        return (a << 10) | (b << 5) | c
    }
}
