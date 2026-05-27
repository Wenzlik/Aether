import Foundation

/// In-memory resume store used during 0.1. Real persistence (SwiftData + outbox) lands in 0.2/0.3.
public actor ResumeStore {
    private var points: [MediaID: ResumePoint] = [:]

    public init() {}

    public func point(for id: MediaID) async -> ResumePoint? {
        points[id]
    }

    public func record(_ point: ResumePoint) async {
        points[point.mediaID] = point
    }
}
