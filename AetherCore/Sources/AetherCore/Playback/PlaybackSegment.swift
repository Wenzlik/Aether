import Foundation

/// A time range within a title that a player can skip or act on — an intro, a
/// recap, the closing credits, a commercial. **Source-provided only**: Plex
/// markers and Jellyfin MediaSegments. Aether never analyses video/audio to
/// detect these; when a source has no data, there are simply no segments and
/// the skip controls stay hidden.
///
/// Times are **seconds** (not `Duration`) so the type is trivially `Codable` —
/// the offline layer persists segments alongside a downloaded title so Skip
/// Intro keeps working on a plane.
public struct PlaybackSegment: Sendable, Hashable, Codable, Identifiable {
    public let kind: Kind
    /// Segment start, seconds from the beginning of the item.
    public let start: Double
    /// Segment end, seconds from the beginning of the item.
    public let end: Double

    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case intro
        case recap
        case credits
        case commercial
        case preview
    }

    public init(kind: Kind, start: Double, end: Double) {
        self.kind = kind
        self.start = start
        self.end = end
    }

    /// Stable across a render — distinguishes overlapping kinds at the same start.
    public var id: String { "\(kind.rawValue):\(Int(start))-\(Int(end))" }

    /// `true` when `time` (seconds) falls inside this segment.
    public func contains(_ time: Double) -> Bool {
        time >= start && time < end
    }
}

public extension Array where Element == PlaybackSegment {
    /// The intro/recap segment currently active at `time`, if any — drives the
    /// "Skip Intro" button's visibility.
    func introSegment(at time: Double) -> PlaybackSegment? {
        first { ($0.kind == .intro || $0.kind == .recap) && $0.contains(time) }
    }

    /// The credits/outro segment active at `time`, if any — drives "Skip
    /// Credits" / the Next Episode prompt.
    func creditsSegment(at time: Double) -> PlaybackSegment? {
        first { $0.kind == .credits && $0.contains(time) }
    }
}
