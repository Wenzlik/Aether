import Foundation

/// Placeholder for the background download manager. Real implementation lands in 0.3.
public actor DownloadManager {
    public init() {}

    public func enqueue(_ item: MediaItem) async throws {
        // Intentionally unimplemented until 0.3 Offline.
    }

    public func cancel(_ id: MediaID) async {
        // Intentionally unimplemented until 0.3 Offline.
    }

    public func localURL(for id: MediaID) async -> URL? { nil }
}
