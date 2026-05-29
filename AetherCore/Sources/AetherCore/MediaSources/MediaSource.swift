import Foundation

/// The shared contract every media source (mock, Plex, Synology) implements.
///
/// Implementations are typically actors — they own auth state and network plumbing.
public protocol MediaSource: Sendable {
    var id: MediaSourceID { get }
    var displayName: String { get }

    /// All top-level libraries this source exposes.
    func libraries() async throws -> [Library]

    /// Items in a given library, paginated by the source as it sees fit.
    func items(in library: Library.ID) async throws -> [MediaItem]

    /// Children of a container item — a show's seasons, a season's episodes.
    /// Returns `[]` for leaf items (movies, episodes) and for sources that
    /// don't model a hierarchy.
    func children(of id: MediaID) async throws -> [MediaItem]
}

public extension MediaSource {
    /// Default: no hierarchy. Plex overrides this to expose seasons + episodes.
    func children(of id: MediaID) async throws -> [MediaItem] { [] }
}

public struct Library: Identifiable, Hashable, Sendable {
    public let id: ID
    public let title: String
    public let kind: MediaItem.Kind

    public init(id: ID, title: String, kind: MediaItem.Kind) {
        self.id = id
        self.title = title
        self.kind = kind
    }

    public struct ID: Hashable, Sendable {
        public let source: MediaSourceID
        public let rawValue: String

        public init(source: MediaSourceID, rawValue: String) {
            self.source = source
            self.rawValue = rawValue
        }
    }
}
