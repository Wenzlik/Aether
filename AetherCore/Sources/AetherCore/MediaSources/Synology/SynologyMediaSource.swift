import Foundation

/// Placeholder for the Synology connector. Real implementation lands in 0.2.
public actor SynologyMediaSource: MediaSource {
    public let id: MediaSourceID
    public let displayName: String

    public init(host: String, displayName: String) {
        self.id = .synology(host: host)
        self.displayName = displayName
    }

    public func libraries() async throws -> [Library] { [] }

    public func items(in libraryID: Library.ID) async throws -> [MediaItem] { [] }
}
