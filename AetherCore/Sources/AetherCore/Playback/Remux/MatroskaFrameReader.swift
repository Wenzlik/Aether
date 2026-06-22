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
        static let position: UInt32     = 0xA7
        static let prevSize: UInt32     = 0xAB
    }

    /// Cluster-level child IDs. An element id *not* in this set marks the start
    /// of the next top-level element, so the current (possibly unknown-size)
    /// cluster ends there.
    private static let clusterChildIDs: Set<UInt32> = [
        ID.timestamp, ID.simpleBlock, ID.blockGroup, ID.position, ID.prevSize
    ]

    /// Parse the cluster whose element header starts at `offset`. Returns the
    /// frames it contains and the offset of the next element (cluster or
    /// sibling), or `nil` if `offset` isn't a cluster.
    static func readCluster(_ data: Data, at offset: Int) -> (frames: [MatroskaFrame], nextOffset: Int)? {
        readCluster(DataByteSource(data), at: offset)
    }

    static func readCluster(_ source: any ByteSource, at offset: Int) -> (frames: [MatroskaFrame], nextOffset: Int)? {
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

            // A non-cluster-child id is the next top-level element — the cluster
            // ends here (handles unknown-size clusters).
            guard clusterChildIDs.contains(childID) else {
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
                                     clusterTimestamp: clusterTimestamp, keyframeOverride: nil)
                reader.seek(to: childEnd)
            case ID.blockGroup:
                frames += parseBlockGroup(&reader, end: childEnd, clusterTimestamp: clusterTimestamp)
                reader.seek(to: childEnd)
            default:
                reader.skip(len)   // Position / PrevSize
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

    // MARK: - BlockGroup

    private static func parseBlockGroup(_ reader: inout EBMLReader, end: Int, clusterTimestamp: Int64) -> [MatroskaFrame] {
        // A Block inside a BlockGroup is a keyframe iff it has no ReferenceBlock.
        // BlockGroup children can appear in any order, so scan for the Block and
        // any ReferenceBlock, then parse the block with the resolved keyframe flag.
        var blockRange: (start: Int, end: Int)?
        var hasReference = false

        while reader.offset < end {
            guard let id = reader.readElementID(), case let .known(size)? = reader.readSize() else { break }
            let len = Int(size)
            let childEnd = reader.offset + len
            switch id {
            case ID.block:          blockRange = (reader.offset, childEnd); reader.seek(to: childEnd)
            case ID.referenceBlock: hasReference = true; reader.skip(len)
            default:                reader.skip(len)
            }
        }

        guard let range = blockRange else { return [] }
        var blockReader = EBMLReader(reader.source, offset: range.start)
        return parseBlock(&blockReader, end: range.end,
                          clusterTimestamp: clusterTimestamp, keyframeOverride: !hasReference)
    }

    // MARK: - Block / SimpleBlock payload

    /// Parse a block payload `[reader.offset, end)`. `keyframeOverride` is set by
    /// BlockGroup (from ReferenceBlock presence); `nil` for a SimpleBlock, whose
    /// keyframe bit lives in its own flags byte.
    private static func parseBlock(_ reader: inout EBMLReader, end: Int, clusterTimestamp: Int64, keyframeOverride: Bool?) -> [MatroskaFrame] {
        guard let track = reader.readVInt(),
              let relRaw = reader.readUInt(length: 2),
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
                                        isKeyframe: isKeyframe, data: data))
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
