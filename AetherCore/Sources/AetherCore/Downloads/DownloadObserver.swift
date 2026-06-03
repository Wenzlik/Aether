import Foundation
import Observation

/// `@MainActor`-bound, `@Observable` adapter that mirrors `DownloadStore`'s
/// state into a value SwiftUI views can read synchronously.
///
/// Why this exists: actors (`DownloadStore`) can't be reached from a view's
/// `body` without `await`, but SwiftUI re-renders synchronously based on
/// observable property reads. The observer holds the latest
/// `DownloadSnapshot`, subscribes to the store's stream, and republishes —
/// so a poster card asking `observer.snapshot.status(for: item.id)` gets a
/// value in `body` without actor hops.
///
/// Lifecycle is automatic: the subscription Task captures `[weak self]`, so
/// when the observer deallocates the loop's `guard self` exits, the
/// `for await` iterator drops, and `DownloadStore`'s `onTermination`
/// handler removes our continuation. No explicit cancel / deinit needed.
@MainActor
@Observable
public final class DownloadObserver {
    /// The latest mirror of the store. `Equatable` so SwiftUI's diffing can
    /// short-circuit when nothing changed.
    public private(set) var snapshot: DownloadSnapshot = .empty

    private let store: DownloadStore

    public init(store: DownloadStore) {
        self.store = store
        Task { [weak self, store] in
            for await snapshot in await store.snapshotStream() {
                guard let self else { return }
                self.snapshot = snapshot
            }
        }
    }

    /// O(1) convenience for the common per-card lookup.
    public func status(for mediaID: MediaID) -> DownloadStatus {
        snapshot.status(for: mediaID)
    }

    public func job(for mediaID: MediaID) -> DownloadJob? {
        snapshot.job(for: mediaID)
    }
}
