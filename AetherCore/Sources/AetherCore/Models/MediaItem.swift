import Foundation

/// A unified, source-agnostic media item.
///
/// Both Plex and Synology connectors map their native types into `MediaItem`
/// so views, navigation, and playback never have to branch on the source.
public struct MediaItem: Identifiable, Hashable, Sendable {
    public let id: MediaID
    public let title: String
    public let kind: Kind
    public let year: Int?
    public let runtime: Duration?
    public let summary: String?
    public let posterURL: URL?
    public let backdropURL: URL?
    public let streamURL: URL?

    public init(
        id: MediaID,
        title: String,
        kind: Kind,
        year: Int? = nil,
        runtime: Duration? = nil,
        summary: String? = nil,
        posterURL: URL? = nil,
        backdropURL: URL? = nil,
        streamURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.year = year
        self.runtime = runtime
        self.summary = summary
        self.posterURL = posterURL
        self.backdropURL = backdropURL
        self.streamURL = streamURL
    }

    public enum Kind: String, Sendable, Hashable {
        case movie
        case episode
        case show
        case season

        /// Whether this kind is a container browsed into for children (a show's
        /// seasons, a season's episodes) rather than played directly.
        public var isContainer: Bool {
            self == .show || self == .season
        }
    }
}

/// Identity of a media item, scoped by its source.
public struct MediaID: Hashable, Sendable {
    public let source: MediaSourceID
    public let rawValue: String

    public init(source: MediaSourceID, rawValue: String) {
        self.source = source
        self.rawValue = rawValue
    }
}

/// Identifies which source (mock / Plex server / Synology share) an item came from.
public enum MediaSourceID: Hashable, Sendable {
    case mock
    case plex(serverID: String)
    case synology(host: String)

    /// A stable, run-to-run identical string for this source. Suitable as a
    /// component of persistence keys (e.g. per-library preferences). The
    /// default `String(describing:)` reflects the underlying Swift enum
    /// representation and is *not* stable across compiler versions, so we
    /// hand-roll one here.
    public var stableKey: String {
        switch self {
        case .mock:
            return "mock"
        case .plex(let serverID):
            return "plex.\(serverID)"
        case .synology(let host):
            return "synology.\(host)"
        }
    }
}
