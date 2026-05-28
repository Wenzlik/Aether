import Foundation
import AVFoundation
import Observation

/// Bridges a `PlaybackSession` (actor) to a SwiftUI player view.
///
/// The view reads `player` to feed `VideoPlayer(player:)` and `state` for
/// chrome and overlays. The view model owns the small Task that polls the
/// session for state snapshots while the player is open.
@MainActor
@Observable
public final class PlayerStateViewModel {
    /// The underlying AVPlayer, vended by the session for SwiftUI to render.
    public private(set) var player: AVPlayer?

    /// The most recent `PlaybackState` snapshot from the session.
    public private(set) var state: PlaybackState = .init()

    private let session: PlaybackSession
    private var refreshTask: Task<Void, Never>?
    private let refreshInterval: Duration

    public init(session: PlaybackSession, refreshInterval: Duration = .milliseconds(500)) {
        self.session = session
        self.refreshInterval = refreshInterval
    }

    /// Open an item and start playback. Idempotent for the same item.
    public func open(_ item: MediaItem) async {
        await session.prepare(item: item)
        await refresh()
        startRefreshing()
        await session.play()
        await refresh()
    }

    public func play() async {
        await session.play()
        await refresh()
    }

    public func pause() async {
        await session.pause()
        await refresh()
    }

    public func seek(to position: Duration) async {
        await session.seek(to: position)
        await refresh()
    }

    /// Stop playback and tear down the player. Call this in `.onDisappear`.
    public func close() async {
        refreshTask?.cancel()
        refreshTask = nil
        await session.stop()
        await refresh()
    }

    // MARK: - Internals

    private func startRefreshing() {
        refreshTask?.cancel()
        let interval = refreshInterval
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self?.refresh()
            }
        }
    }

    private func refresh() async {
        let snapshot = await session.state
        let avPlayer = await session.currentAVPlayer()
        self.state = snapshot
        self.player = avPlayer
    }
}
