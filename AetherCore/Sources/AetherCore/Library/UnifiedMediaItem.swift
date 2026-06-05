import Foundation

/// A source kind, ordered by **playback priority** (raw value = priority, lower
/// wins). Offline first (no bandwidth, works on a plane), then the servers.
/// `emby` is reserved for the upcoming connector.
public enum MediaSourceKind: Int, Comparable, Sendable, Hashable {
    case offline = 0
    case plex = 1
    case jellyfin = 2
    case emby = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The streaming kind for a concrete `MediaSourceID`. Offline is derived
    /// separately (from the downloads store), not from an id. `nil` for kinds
    /// that aren't part of the unified priority yet (mock, Synology).
    public init?(streaming source: MediaSourceID) {
        switch source {
        case .plex:     self = .plex
        case .jellyfin: self = .jellyfin
        case .synology, .mock: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .offline:  return "Offline"
        case .plex:     return "Plex"
        case .jellyfin: return "Jellyfin"
        case .emby:     return "Emby"
        }
    }
}

/// One concrete source behind a unified title — the real per-source `MediaItem`
/// plus display metadata. Playback/download reuse `item` through the existing
/// `MediaSource`, so the unified layer adds no new playback path.
public struct UnifiedSource: Identifiable, Hashable, Sendable {
    public let kind: MediaSourceKind
    public let item: MediaItem
    public let serverName: String?
    public let playable: Bool

    public init(kind: MediaSourceKind, item: MediaItem, serverName: String? = nil, playable: Bool = true) {
        self.kind = kind
        self.item = item
        self.serverName = serverName
        self.playable = playable
    }

    /// Stable across a render — distinguishes the streaming vs offline copy of
    /// the same underlying item.
    public var id: String {
        "\(kind.rawValue):\(item.id.source.stableKey):\(item.id.rawValue)"
    }

    /// Short quality label for the Detail "Available Sources" rows, when known.
    public var quality: String? {
        item.mediaInfo?.videoResolution
    }
}

/// A title aggregated across every source that has it — the unit the unified UI
/// renders. The source becomes an implementation detail: one row, multiple
/// sources behind it.
public struct UnifiedMediaItem: Identifiable, Hashable, Sendable {
    public let id: String          // derived from the strongest shared external id
    public let title: String
    public let year: Int?
    public let overview: String?
    public let posterURL: URL?
    public let backdropURL: URL?
    public let type: MediaItem.Kind
    /// Sorted by priority (offline → plex → jellyfin → emby).
    public let sources: [UnifiedSource]

    public init(
        id: String,
        title: String,
        year: Int?,
        overview: String?,
        posterURL: URL?,
        backdropURL: URL?,
        type: MediaItem.Kind,
        sources: [UnifiedSource]
    ) {
        self.id = id
        self.title = title
        self.year = year
        self.overview = overview
        self.posterURL = posterURL
        self.backdropURL = backdropURL
        self.type = type
        self.sources = sources
    }

    /// The source playback should use: highest-priority playable source.
    public var preferredSource: UnifiedSource? {
        sources.filter(\.playable).min { $0.kind < $1.kind }
    }

    /// `true` when an offline (downloaded) copy exists.
    public var isDownloaded: Bool {
        sources.contains { $0.kind == .offline }
    }
}
