import Foundation

/// Placeholder for the Plex connector. Real implementation lands in 0.2.
public actor PlexMediaSource: MediaSource {
    public let id: MediaSourceID
    public let displayName: String

    public init(serverID: String, displayName: String) {
        self.id = .plex(serverID: serverID)
        self.displayName = displayName
    }

    public func libraries() async throws -> [Library] { [] }

    public func items(in libraryID: Library.ID) async throws -> [MediaItem] { [] }
}
