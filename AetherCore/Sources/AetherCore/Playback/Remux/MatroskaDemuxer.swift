import Foundation

/// Parses the **head** of a Matroska (`.mkv`) file — timing + track list — for
/// the pure-Swift remux shim (#476, Tier 1). This is the *probe*: it reads only
/// up to the first `Cluster`, which is enough for `RemuxEngine.canPlay` to learn
/// the codecs and decide whether AVFoundation can play the elementary streams.
/// Frame extraction (clusters → samples) is a separate, later stage that
/// resumes from `firstClusterOffset`.
///
/// Recursive descent over `EBMLReader`, bounded by each master element's stated
/// size. Defensive throughout: unrecognised elements are skipped by size and a
/// truncated/garbage file throws rather than trapping.
enum MatroskaDemuxer {

    enum DemuxError: Error, Equatable {
        case notMatroska   // missing/!= EBML header magic
        case truncated     // ran off the end mid-element
        case noTracks      // reached clusters/EOF without a Tracks element
    }

    // MARK: Element IDs (canonical, marker bit kept)

    private enum ID {
        static let ebmlHeader: UInt32     = 0x1A45DFA3
        static let segment: UInt32        = 0x18538067
        static let info: UInt32           = 0x1549A966
        static let timestampScale: UInt32 = 0x2AD7B1
        static let duration: UInt32       = 0x4489
        static let tracks: UInt32         = 0x1654AE6B
        static let trackEntry: UInt32     = 0xAE
        static let trackNumber: UInt32    = 0xD7
        static let trackType: UInt32      = 0x83
        static let codecID: UInt32        = 0x86
        static let codecPrivate: UInt32   = 0x63A2
        static let defaultDuration: UInt32 = 0x23E383
        static let language: UInt32       = 0x22B59C
        static let name: UInt32           = 0x536E
        static let flagDefault: UInt32    = 0x88
        static let flagForced: UInt32     = 0x55AA
        static let video: UInt32          = 0xE0
        static let pixelWidth: UInt32     = 0xB0
        static let pixelHeight: UInt32    = 0xBA
        static let audio: UInt32          = 0xE1
        static let samplingFrequency: UInt32 = 0xB5
        static let channels: UInt32       = 0x9F
        static let bitDepth: UInt32       = 0x6264
        static let cluster: UInt32        = 0x1F43B675
    }

    // MARK: - Probe

    static func probe(_ data: Data) throws -> MatroskaSegmentInfo {
        var reader = EBMLReader(data)

        // 1) EBML header — must be present; we don't need its body.
        guard let headerID = reader.readElementID(), headerID == ID.ebmlHeader,
              case let .known(headerSize)? = reader.readSize() else {
            throw DemuxError.notMatroska
        }
        reader.skip(Int(headerSize))

        // 2) Segment — the container for everything else. May carry an "unknown"
        //    size (stream to EOF), in which case we bound by the buffer.
        guard let segmentID = reader.readElementID(), segmentID == ID.segment,
              let segmentSize = reader.readSize() else {
            throw DemuxError.notMatroska
        }
        let segmentEnd: Int
        switch segmentSize {
        case .known(let s): segmentEnd = min(reader.count, reader.offset + Int(s))
        case .unknown:      segmentEnd = reader.count
        }

        // 3) Walk Segment children, descending only into Info and Tracks, until
        //    the first Cluster (frame data) or the segment's end.
        var info = MatroskaInfo()
        var tracks: [MatroskaTrack]?
        var firstClusterOffset: Int?

        while reader.offset < segmentEnd {
            // Capture the element's header start *before* consuming id+size, so a
            // cluster's recorded offset points at the element, not its body.
            let elementStart = reader.offset
            guard let id = reader.readElementID(), let size = reader.readSize() else { break }
            switch (id, size) {
            case (ID.cluster, _):
                // Probe stops at the first cluster — Info/Tracks precede it.
                firstClusterOffset = elementStart
                reader.seek(to: segmentEnd)   // stop the walk
            case (ID.info, .known(let s)):
                info = parseInfo(&reader, end: reader.offset + Int(s))
            case (ID.tracks, .known(let s)):
                tracks = parseTracks(&reader, end: reader.offset + Int(s))
            case (_, .known(let s)):
                reader.skip(Int(s))           // unrecognised — skip by size
            case (_, .unknown):
                reader.seek(to: segmentEnd)   // can't skip an unknown-size leaf
            }
        }

        guard let tracks else { throw DemuxError.noTracks }
        return MatroskaSegmentInfo(info: info, tracks: tracks, firstClusterOffset: firstClusterOffset)
    }

    // MARK: - Info

    private static func parseInfo(_ reader: inout EBMLReader, end: Int) -> MatroskaInfo {
        var scale: UInt64 = 1_000_000
        var duration: Double?
        while reader.offset < end {
            guard let id = reader.readElementID(), case let .known(size)? = reader.readSize() else { break }
            let len = Int(size)
            switch id {
            case ID.timestampScale: scale = reader.readUInt(length: len) ?? scale
            case ID.duration:       duration = reader.readFloat(length: len)
            default:                reader.skip(len)
            }
        }
        return MatroskaInfo(timestampScaleNs: scale, durationTicks: duration)
    }

    // MARK: - Tracks

    private static func parseTracks(_ reader: inout EBMLReader, end: Int) -> [MatroskaTrack] {
        var tracks: [MatroskaTrack] = []
        while reader.offset < end {
            guard let id = reader.readElementID(), case let .known(size)? = reader.readSize() else { break }
            let len = Int(size)
            if id == ID.trackEntry {
                if let track = parseTrackEntry(&reader, end: reader.offset + len) { tracks.append(track) }
            } else {
                reader.skip(len)
            }
        }
        return tracks
    }

    private static func parseTrackEntry(_ reader: inout EBMLReader, end: Int) -> MatroskaTrack? {
        var number: UInt64?
        var rawType: UInt64?
        var codecID: String?
        var codecPrivate: [UInt8]?
        var language: String?
        var name: String?
        var isDefault = true   // Matroska FlagDefault defaults to 1
        var isForced = false
        var defaultDuration: UInt64?
        var pixelWidth: UInt64?
        var pixelHeight: UInt64?
        var channels: UInt64?
        var sampleRate: Double?
        var bitDepth: UInt64?

        while reader.offset < end {
            guard let id = reader.readElementID(), case let .known(size)? = reader.readSize() else { break }
            let len = Int(size)
            switch id {
            case ID.trackNumber:     number = reader.readUInt(length: len)
            case ID.trackType:       rawType = reader.readUInt(length: len)
            case ID.codecID:         codecID = reader.readString(length: len)
            case ID.codecPrivate:    codecPrivate = reader.readBytes(length: len)
            case ID.language:        language = reader.readString(length: len)
            case ID.name:            name = reader.readString(length: len)
            case ID.flagDefault:     isDefault = (reader.readUInt(length: len) ?? 1) != 0
            case ID.flagForced:      isForced = (reader.readUInt(length: len) ?? 0) != 0
            case ID.defaultDuration: defaultDuration = reader.readUInt(length: len)
            case ID.video:           (pixelWidth, pixelHeight) = parseVideo(&reader, end: reader.offset + len)
            case ID.audio:           (channels, sampleRate, bitDepth) = parseAudio(&reader, end: reader.offset + len)
            default:                 reader.skip(len)
            }
        }

        guard let number, let rawType, let codecID else { return nil }
        return MatroskaTrack(
            number: number,
            type: MatroskaTrackType(rawTrackType: rawType),
            codecID: codecID,
            codecPrivate: codecPrivate,
            language: language,
            name: name,
            isDefault: isDefault,
            isForced: isForced,
            defaultDurationNs: defaultDuration,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            channels: channels,
            sampleRate: sampleRate,
            bitDepth: bitDepth
        )
    }

    private static func parseVideo(_ reader: inout EBMLReader, end: Int) -> (UInt64?, UInt64?) {
        var w: UInt64?
        var h: UInt64?
        while reader.offset < end {
            guard let id = reader.readElementID(), case let .known(size)? = reader.readSize() else { break }
            let len = Int(size)
            switch id {
            case ID.pixelWidth:  w = reader.readUInt(length: len)
            case ID.pixelHeight: h = reader.readUInt(length: len)
            default:             reader.skip(len)
            }
        }
        return (w, h)
    }

    private static func parseAudio(_ reader: inout EBMLReader, end: Int) -> (UInt64?, Double?, UInt64?) {
        var channels: UInt64?
        var rate: Double?
        var depth: UInt64?
        while reader.offset < end {
            guard let id = reader.readElementID(), case let .known(size)? = reader.readSize() else { break }
            let len = Int(size)
            switch id {
            case ID.channels:          channels = reader.readUInt(length: len)
            case ID.samplingFrequency: rate = reader.readFloat(length: len)
            case ID.bitDepth:          depth = reader.readUInt(length: len)
            default:                   reader.skip(len)
            }
        }
        return (channels, rate, depth)
    }
}
