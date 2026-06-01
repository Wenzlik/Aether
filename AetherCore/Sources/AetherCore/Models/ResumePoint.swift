import Foundation

/// A resume position for a particular media item.
///
/// Resume points are always written locally first; the server copy is best-effort.
/// Round-trips through `ResumeStore`'s disk JSON + iCloud key-value store via a
/// hand-rolled wire type inside the store, so this struct stays Codable-free
/// and the domain model doesn't need to know about persistence.
public struct ResumePoint: Hashable, Sendable {
    public let mediaID: MediaID
    public let position: Duration
    public let updatedAt: Date

    public init(mediaID: MediaID, position: Duration, updatedAt: Date = .now) {
        self.mediaID = mediaID
        self.position = position
        self.updatedAt = updatedAt
    }
}
