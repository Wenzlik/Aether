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

    /// Source-provided skip segments for the playing item (intro / credits /
    /// …). Fetched once on `open`; empty when the source has no data.
    public private(set) var segments: [PlaybackSegment] = []

    /// Live absolute content position in seconds, refreshed every tick — drives
    /// the Skip Intro / Skip Credits buttons (the resume loop is too coarse).
    public private(set) var currentSeconds: Double = 0

    private let session: PlaybackSession
    private var refreshTask: Task<Void, Never>?
    private let refreshInterval: Duration

    public init(session: PlaybackSession, refreshInterval: Duration = .milliseconds(500)) {
        self.session = session
        self.refreshInterval = refreshInterval
    }

    /// Open an item and start playback. Idempotent for the same item.
    ///
    /// `source` resolves a fresh playback URL (Plex mints a new transcode
    /// session); pass the source the item came from. `startAt` is forwarded to
    /// the session: `nil` resumes from the persisted point, an explicit value
    /// (e.g. `0`) starts there regardless.
    public func open(_ item: MediaItem, source: (any MediaSource)? = nil, startAt: Double? = nil) async {
        await session.prepare(item: item, source: source, startAt: startAt)
        await refresh()
        startRefreshing()
        await session.play()
        await refresh()
        // Skip segments (intro / credits) — best-effort, never blocks playback.
        segments = await source?.segments(for: item.id) ?? []
    }

    /// Seek past a skip segment (absolute content seconds), accounting for the
    /// transcode base offset.
    public func skip(toContentSeconds target: Double) async {
        await session.skip(toContentSeconds: target)
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

    /// Track the app's foreground/background state (drive from `scenePhase`).
    /// While backgrounded there's no visible player UI, so the 500 ms refresh
    /// poll is suspended entirely — audio keeps playing via the background-audio
    /// mode, but we stop burning CPU 2×/second behind the lock screen (battery /
    /// heat). It resumes, with an immediate refresh, on return to foreground.
    public func setAppActive(_ isActive: Bool) {
        guard player != nil else { return }   // nothing open → nothing to poll
        if isActive {
            startRefreshing()
            Task { await refresh() }
        } else {
            refreshTask?.cancel()
            refreshTask = nil
        }
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

        // Surface AVPlayer failures into the session. The session itself doesn't
        // KVO the player (it lives on its own actor); we check here on
        // @MainActor where the AVPlayer/AVPlayerItem are safe to touch and hand
        // the failure to the session, which tries **one** automatic recovery
        // (re-resolve a fresh, warmed URL at the last position) before failing.
        // Skip while `.loading` so we don't poke a recovery/open already in
        // flight (its player may briefly still be the old, failed one).
        if snapshot.status != .failed, snapshot.status != .loading,
           let message = avplayerFailureMessage(player: avPlayer) {
            await session.recoverOrFail(message: message)
            self.state = await session.state
            self.player = await session.currentAVPlayer()
            return
        }

        self.state = snapshot
        self.player = avPlayer
        self.currentSeconds = await session.currentPositionSeconds()
    }

    /// Build a short, user-readable hint from `AVPlayer.error` /
    /// `AVPlayerItem.error`. Falls back to a sentinel when playback failed
    /// without an attached error (rare but possible for malformed manifests).
    @MainActor
    private func avplayerFailureMessage(player: AVPlayer?) -> String? {
        guard let player else { return nil }
        if player.status == .failed {
            return avplayerErrorMessage(error: player.error)
        }
        guard let item = player.currentItem, item.status == .failed else {
            return nil
        }
        return avplayerErrorMessage(error: item.error)
    }

    @MainActor
    private func avplayerErrorMessage(error: (any Error)?) -> String {
        if let error = error as NSError? {
            // `localizedDescription` is usually one line; we include the
            // domain + code so developer-side reports survive translation.
            return "AVPlayer: \(error.localizedDescription) (\(error.domain) \(error.code))"
        }
        return "AVPlayer reported a failure without an attached error."
    }

}
