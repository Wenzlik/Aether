import Foundation

/// A snapshot of what the Home screen renders for the current source.
///
/// `HomeFeed` is a value type built by `HomeFeedBuilder` from a `MediaSource` and
/// a `ResumeStore`. The view layer receives it as-is and walks it top-down — no
/// observation, no async work in `body`.
public struct HomeFeed: Sendable, Equatable {
    public let featured: [MediaItem]
    public let continueWatching: [ContinueWatchingEntry]
    public let libraries: [LibrarySection]

    public init(
        featured: [MediaItem],
        continueWatching: [ContinueWatchingEntry],
        libraries: [LibrarySection]
    ) {
        self.featured = featured
        self.continueWatching = continueWatching
        self.libraries = libraries
    }

    public static let empty = HomeFeed(featured: [], continueWatching: [], libraries: [])

    public struct ContinueWatchingEntry: Sendable, Equatable, Identifiable {
        public var id: MediaID { item.id }
        public let item: MediaItem
        public let resume: ResumePoint

        public init(item: MediaItem, resume: ResumePoint) {
            self.item = item
            self.resume = resume
        }

        /// Fractional progress (0…1). Returns `nil` when the item has no known runtime.
        public var progress: Double? {
            guard let runtime = item.runtime, runtime > .zero else { return nil }
            let runtimeSeconds = Self.seconds(runtime)
            let positionSeconds = Self.seconds(resume.position)
            guard runtimeSeconds > 0 else { return nil }
            return min(1.0, max(0.0, positionSeconds / runtimeSeconds))
        }

        private static func seconds(_ duration: Duration) -> Double {
            let parts = duration.components
            return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        }
    }

    public struct LibrarySection: Sendable, Equatable, Identifiable {
        public var id: Library.ID { library.id }
        public let library: Library
        public let items: [MediaItem]

        public init(library: Library, items: [MediaItem]) {
            self.library = library
            self.items = items
        }
    }
}
