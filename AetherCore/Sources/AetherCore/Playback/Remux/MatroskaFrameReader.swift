import Foundation

/// Extracts coded frames from Matroska clusters for the remux shim (#476,
/// Tier 1). Picks up where `MatroskaDemuxer.probe` left off (`firstClusterOffset`)
/// and turns `SimpleBlock` / `BlockGroup` payloads into `MatroskaFrame`s — track,
/// absolute timestamp, keyframe flag, raw coded bytes.
///
/// Works **one cluster at a time** (`readCluster` returns the next offset) so the
/// remux pipeline can stream clusters on demand rather than loading a multi-GB
/// file into memory. Handles all four EBML lacing modes (none/Xiph/fixed/EBML)
/// and both known- and unknown-size clusters (it stops at the next top-level
/// element, identified by id). Defensive: malformed input yields the frames
/// parsed so far, never a trap.
enum MatroskaFrameReader {

    private enum ID {
        static let cluster: UInt32      = 0x1F43B675
        static let timestamp: UInt32    = 0xE7
        static let simpleBlock: UInt32  = 0xA3
        static let blockGroup: UInt32   = 0xA0
        static let block: UInt32        = 0xA1
        static let referenceBlock: UInt32 = 0xFB
        static let blockDuration: UInt32 = 0x9B
        static let position: UInt32     = 0xA7
        static let prevSize: UInt32     = 0xAB
    }

    /// Top-level Segment elements. Hitting one of these ends the current cluster
    /// (used for unknown-size clusters, which have no length to stop at). Any
    /// *other* unrecognised id inside a cluster — CRC-32 (`0xBF`), Void (`0xEC`),
    /// or a future element — is skipped by size, **not** treated as a boundary.
    /// (ffmpeg writes a per-cluster CRC-32 as the first child; treating it as a
    /// boundary made every ffmpeg-muxed cluster read as empty.)
    private static let topLevelSiblingIDs: Set<UInt32> = [
        0x1F43B675,  // Cluster
        0x1C53BB6B,  // Cues
        0x1043A770,  // Chapters
        0x1254C367,  // Tags
        0x1941A469,  // Attachments
        0x114D9B74,  // SeekHead
        0x1549A966,  // Info
        0x1654AE6B   // Tracks
    ]

    /// Parse the cluster whose element header starts at `offset`. Returns the
    /// frames it contains and the offset of the next element (cluster or
    /// sibling), or `nil` if `offset` isn't a cluster.
    static func readCluster(_ data: Data, at offset: Int) -> (frames: [MatroskaFrame], nextOffset: Int)? {
        readCluster(DataByteSource(data), at: offset)
    }

    static func readCluster(_ source: any ByteSource, at offset: Int,
                            trackFilter: Set<UInt64>? = nil) -> (frames: [MatroskaFrame], nextOffset: Int)? {
        var reader = EBMLReader(source, offset: offset)
        guard let id = reader.readElementID(), id == ID.cluster,
              let size = reader.readSize() else { return nil }

        let boundedEnd: Int
        switch size {
        case .known(let s): boundedEnd = min(source.count, reader.offset + Int(s))
        case .unknown:      boundedEnd = source.count
        }

        var clusterTimestamp: Int64 = 0
        var frames: [MatroskaFrame] = []
        var nextOffset = boundedEnd

        while reader.offset < boundedEnd {
            let childStart = reader.offset
            guard let childID = reader.readElementID() else { break }

            // The next top-level Segment element marks the end of this cluster
            // (handles unknown-size clusters).
            if Self.topLevelSiblingIDs.contains(childID) {
                nextOffset = childStart
                break
            }
            guard case let .known(childSize)? = reader.readSize() else { break }
            let len = Int(childSize)
            let childEnd = reader.offset + len

            switch childID {
            case ID.timestamp:
                clusterTimestamp = Int64(reader.readUInt(length: len) ?? 0)
            case ID.simpleBlock:
                frames += parseBlock(&reader, end: childEnd,
                                     clusterTimestamp: clusterTimestamp, keyframeOverride: nil,
                                     trackFilter: trackFilter)
                reader.seek(to: childEnd)
            case ID.blockGroup:
                frames += parseBlockGroup(&reader, end: childEnd, clusterTimestamp: clusterTimestamp,
                                          trackFilter: trackFilter)
                reader.seek(to: childEnd)
            default:
                reader.skip(len)   // Position / PrevSize / CRC-32 / Void / unknown
            }
        }

        return (frames, nextOffset)
    }

    /// Read every frame from `firstOffset` to EOF — convenience for small files
    /// and tests. Streaming callers use `readCluster` directly.
    static func readAllFrames(_ data: Data, from firstOffset: Int) -> [MatroskaFrame] {
        readAllFrames(DataByteSource(data), from: firstOffset)
    }

    static func readAllFrames(_ source: any ByteSource, from firstOffset: Int) -> [MatroskaFrame] {
        var frames: [MatroskaFrame] = []
        var offset = firstOffset
        while offset < source.count {
            guard let (clusterFrames, next) = readCluster(source, at: offset), next > offset else { break }
            frames += clusterFrames
            offset = next
        }
        return frames
    }

    /// Read only the frames belonging to `trackNumbers` (the subtitle tracks),
    /// from `firstOffset` to EOF. The `trackFilter` makes `parseBlock` skip other
    /// tracks' payloads without copying them — so this walks the whole file's
    /// block structure but copies only the tiny subtitle blocks, never the
    /// gigabytes of A/V sample data. Used to build the eager WebVTT segment
    /// (#476 P6).
    static func readSubtitleFrames(_ source: any ByteSource, from firstOffset: Int,
                                   trackNumbers: Set<UInt64>) -> [MatroskaFrame] {
        guard !trackNumbers.isEmpty else { return [] }
        var frames: [MatroskaFrame] = []
        var offset = firstOffset
        while offset < source.count {
            guard let (clusterFrames, next) = readCluster(source, at: offset, trackFilter: trackNumbers),
                  next > offset else { break }
            frames += clusterFrames
            offset = next
        }
        return frames
    }

    // MARK: - BlockGroup

    private static func parseBlockGroup(_ reader: inout EBMLReader, end: Int, clusterTimestamp: Int64,
                                        trackFilter: Set<UInt64>? = nil) -> [MatroskaFrame] {
        // A Block inside a BlockGroup is a keyframe iff it has no ReferenceBlock.
        // BlockGroup children can appear in any order, so scan for the Block and
        // any ReferenceBlock, then parse the block with the resolved keyframe flag.
        var blockRange: (start: Int, end: Int)?
        var hasReference = false
        var duration: Int64?

        while reader.offset < end {
            guard let id = reader.readElementID(), case let .known(size)? = reader.readSize() else { break }
            let len = Int(size)
            let childEnd = reader.offset + len
            switch id {
            case ID.block:          blockRange = (reader.offset, childEnd); reader.seek(to: childEnd)
            case ID.referenceBlock: hasReference = true; reader.skip(len)
            case ID.blockDuration:  duration = reader.readUInt(length: len).map(Int64.init)
            default:                reader.skip(len)
            }
        }

        guard let range = blockRange else { return [] }
        var blockReader = EBMLReader(reader.source, offset: range.start)
        return parseBlock(&blockReader, end: range.end, clusterTimestamp: clusterTimestamp,
                          keyframeOverride: !hasReference, durationTicks: duration,
                          trackFilter: trackFilter)
    }

    // MARK: - Size-only scan (for the stream index, no payload copy)

    /// A frame's track + byte size, without its payload. Building the stream
    /// index from these (rather than full media segments) means the index pass
    /// reads only the cluster/block structure — never the gigabytes of sample
    /// data — so first-play isn't gated on a full-file copy.
    struct FrameInfo: Sendable { let trackNumber: UInt64; let size: Int }

    /// Like `readCluster`, but returns per-frame (track, size) without reading
    /// the sample payloads.
    static func readClusterFrameInfo(_ source: any ByteSource, at offset: Int) -> (frames: [FrameInfo], nextOffset: Int)? {
        var reader = EBMLReader(source, offset: offset)
        guard let id = reader.readElementID(), id == ID.cluster, let size = reader.readSize() else { return nil }
        let boundedEnd: Int
        switch size {
        case .known(let s): boundedEnd = min(source.count, reader.offset + Int(s))
        case .unknown:      boundedEnd = source.count
        }

        var frames: [FrameInfo] = []
        var nextOffset = boundedEnd
        while reader.offset < boundedEnd {
            let childStart = reader.offset
            guard let childID = reader.readElementID() else { break }
            if Self.topLevelSiblingIDs.contains(childID) { nextOffset = childStart; break }
            guard case let .known(childSize)? = reader.readSize() else { break }
            let len = Int(childSize)
            let childEnd = reader.offset + len
            switch childID {
            case ID.simpleBlock:
                frames += parseBlockSizes(&reader, end: childEnd)
                reader.seek(to: childEnd)
            case ID.blockGroup:
                frames += parseBlockGroupSizes(&reader, end: childEnd)
                reader.seek(to: childEnd)
            default:
                reader.skip(len)
            }
        }
        return (frames, nextOffset)
    }

    private static func parseBlockGroupSizes(_ reader: inout EBMLReader, end: Int) -> [FrameInfo] {
        while reader.offset < end {
            guard let id = reader.readElementID(), case let .known(size)? = reader.readSize() else { break }
            let len = Int(size)
            if id == ID.block {
                var blockReader = EBMLReader(reader.source, offset: reader.offset)
                return parseBlockSizes(&blockReader, end: reader.offset + len)
            }
            reader.skip(len)
        }
        return []
    }

    /// Read a block's track + per-frame sizes without copying the payload.
    private static func parseBlockSizes(_ reader: inout EBMLReader, end: Int) -> [FrameInfo] {
        guard let track = reader.readVInt(),
              reader.readUInt(length: 2) != nil,   // skip relative timestamp
              let flags = reader.readUInt(length: 1) else { return [] }
        let lacing = (flags >> 1) & 0x03
        return frameSizes(&reader, end: end, lacing: lacing).map { FrameInfo(trackNumber: track, size: $0) }
    }

    // MARK: - Block / SimpleBlock payload

    /// Parse a block payload `[reader.offset, end)`. `keyframeOverride` is set by
    /// BlockGroup (from ReferenceBlock presence); `nil` for a SimpleBlock, whose
    /// keyframe bit lives in its own flags byte.
    private static func parseBlock(_ reader: inout EBMLReader, end: Int, clusterTimestamp: Int64, keyframeOverride: Bool?, durationTicks: Int64? = nil, trackFilter: Set<UInt64>? = nil) -> [MatroskaFrame] {
        guard let track = reader.readVInt() else { return [] }
        // Skip tracks the caller doesn't want before reading their payload — this
        // is what keeps subtitle-only extraction off the A/V sample bytes.
        if let filter = trackFilter, !filter.contains(track) { return [] }
        guard let relRaw = reader.readUInt(length: 2),
              let flags = reader.readUInt(length: 1) else { return [] }

        let relative = Int16(bitPattern: UInt16(truncatingIfNeeded: relRaw))
        let timestamp = clusterTimestamp + Int64(relative)
        let isKeyframe = keyframeOverride ?? ((flags & 0x80) != 0)
        let lacing = (flags >> 1) & 0x03   // 0 none, 1 Xiph, 2 fixed, 3 EBML

        let sizes = frameSizes(&reader, end: end, lacing: lacing)
        var frames: [MatroskaFrame] = []
        for size in sizes {
            guard let data = reader.readBytes(length: size) else { break }
            frames.append(MatroskaFrame(trackNumber: track, timestampTicks: timestamp,
                                        isKeyframe: isKeyframe, data: data, durationTicks: durationTicks))
        }
        return frames
    }

    /// Compute the per-frame byte sizes for the block's lacing mode. The reader
    /// is left positioned at the first frame's data.
    private static func frameSizes(_ reader: inout EBMLReader, end: Int, lacing: UInt64) -> [Int] {
        guard lacing != 0 else { return [end - reader.offset] }   // unlaced: one frame
        guard let countMinus1 = reader.readUInt(length: 1) else { return [] }
        let count = Int(countMinus1) + 1
        guard count >= 1 else { return [] }

        switch lacing {
        case 2: // fixed — all frames equal share of what's left
            let each = (end - reader.offset) / count
            return Array(repeating: each, count: count)

        case 1: // Xiph — (count-1) sizes as sums of 0xFF-terminated bytes
            var sizes: [Int] = []
            for _ in 0..<(count - 1) {
                var size = 0
                while let b = reader.readBytes(length: 1)?.first {
                    size += Int(b)
                    if b != 0xFF { break }
                }
                sizes.append(size)
            }
            sizes.append(max(0, end - reader.offset - sizes.reduce(0, +)))
            return sizes

        case 3: // EBML — first size is a vint, the rest signed deltas
            var sizes: [Int] = []
            guard let first = reader.readVInt() else { return [] }
            sizes.append(Int(first))
            for _ in 0..<(count - 2) where count >= 2 {
                guard let delta = reader.readSignedVInt(), let prev = sizes.last else { break }
                sizes.append(prev + Int(delta))
            }
            sizes.append(max(0, end - reader.offset - sizes.reduce(0, +)))
            return sizes

        default:
            return [end - reader.offset]
        }
    }
}
