import Foundation
import AVFoundation

/// Minimal playback state surfaced to UI.
///
/// A `Sendable` snapshot — never mutated by the view. The view reads it; the
/// view model refreshes it from the session.
public struct PlaybackState: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case idle, loading, playing, paused, ended, failed
    }

    public var status: Status
    public var item: MediaItem?
    public var position: Duration
    public var duration: Duration?
    /// When `status == .failed`, a short user-readable hint describing why.
    /// Filled either by `prepare()` (no stream URL) or by `markFailed(...)`
    /// after the view-model observes `AVPlayerItem.status == .failed`.
    public var error: String?

    public init(
        status: Status = .idle,
        item: MediaItem? = nil,
        position: Duration = .zero,
        duration: Duration? = nil,
        error: String? = nil
    ) {
        self.status = status
        self.item = item
        self.position = position
        self.duration = duration
        self.error = error
    }
}

/// Owns the single `AVPlayer` instance and the resume-write loop.
///
/// Architecture rules (see `docs/architecture/ARCHITECTURE.md` → *Playback*):
/// - One `PlaybackSession` per app process. Re-used across titles; rebuilt only
///   when the source type changes.
/// - `AVPlayer` is `@MainActor` in modern AVKit. The session holds the
///   reference (the class is `Sendable`) and hops to `MainActor` for every
///   method call that touches it.
/// - Resume points are written every ~5s while playing, and on pause/stop.
///   Local first; the server sync layer plugs in at 0.2.
public actor PlaybackSession {
    public private(set) var state: PlaybackState
    private let resumeStore: ResumeStore
    private let resumeWriteInterval: Duration

    private var avPlayer: AVPlayer?
    private var resumeTask: Task<Void, Never>?

    public init(resumeStore: ResumeStore, resumeWriteInterval: Duration = .seconds(5)) {
        self.state = PlaybackState()
        self.resumeStore = resumeStore
        self.resumeWriteInterval = resumeWriteInterval
    }

    // MARK: - Commands

    /// Prepare the session for a new item.
    ///
    /// Tears down any previous player, builds a new `AVPlayer`, seeks to the
    /// persisted resume position if one exists, and starts the resume-write
    /// loop. Does *not* auto-play — call `play()` when the view is ready.
    public func prepare(item: MediaItem) async {
        // Tear down previous session before starting a new one.
        resumeTask?.cancel()
        resumeTask = nil
        await teardownPlayer()

        guard let url = item.streamURL else {
            state = PlaybackState(
                status: .failed,
                item: item,
                error: "Stream URL is missing — Plex didn't return a playable Part."
            )
            return
        }

        let resumeSeconds = await persistedResumeSeconds(for: item.id)
        let player = await MainActor.run { () -> AVPlayer in
            let p = AVPlayer(url: url)
            if resumeSeconds > 0 {
                let cmTime = CMTime(seconds: resumeSeconds, preferredTimescale: 600)
                p.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            return p
        }

        self.avPlayer = player
        self.state = PlaybackState(
            status: .loading,
            item: item,
            position: .seconds(resumeSeconds)
        )
        startResumeLoop()
    }

    public func play() async {
        guard let avPlayer, state.item != nil else { return }
        await MainActor.run { avPlayer.play() }
        state.status = .playing
    }

    public func pause() async {
        guard let avPlayer, state.status == .playing else { return }
        await MainActor.run { avPlayer.pause() }
        state.status = .paused
        await writeResumeNow()
    }

    public func seek(to position: Duration) async {
        guard let avPlayer else { return }
        let seconds = Self.durationSeconds(position)
        let cmTime = CMTime(seconds: seconds, preferredTimescale: 600)
        await MainActor.run {
            avPlayer.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        state.position = position
    }

    /// Switch Plex transcoder audio streams without forcing the user back to
    /// the detail screen. PMS exposes audio selection as a transcoder query
    /// item (`audioStreamID`), so changing tracks means replacing the current
    /// player item with the same URL plus the selected stream id.
    public func selectAudioTrack(_ track: MediaAudioTrack) async {
        guard let item = state.item,
              item.audioTracks.contains(where: { $0.id == track.id }) else { return }
        let nextItem = item.selectingAudioTrack(track)
        guard let url = nextItem.streamURL else { return }

        let wasPlaying = state.status == .playing
        let priorStatus = state.status
        let seconds = await currentPlaybackSeconds()
        let cmTime = CMTime(seconds: seconds, preferredTimescale: 600)

        if let avPlayer {
            await MainActor.run {
                avPlayer.replaceCurrentItem(with: AVPlayerItem(url: url))
                avPlayer.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
                if wasPlaying {
                    avPlayer.play()
                }
            }
        } else {
            let player = await MainActor.run { () -> AVPlayer in
                let player = AVPlayer(url: url)
                player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
                if wasPlaying {
                    player.play()
                }
                return player
            }
            avPlayer = player
            startResumeLoop()
        }

        state = PlaybackState(
            status: wasPlaying ? .playing : priorStatus,
            item: nextItem,
            position: .seconds(seconds),
            duration: state.duration
        )
    }

    public func stop() async {
        resumeTask?.cancel()
        resumeTask = nil
        await writeResumeNow()
        await teardownPlayer()
        state = PlaybackState()
    }

    /// Called by the view model when it observes that the underlying
    /// `AVPlayerItem` has flipped to `.failed`. Without this, an AVPlayer
    /// network/codec/TLS failure would leave the session sitting at
    /// `.loading` or `.playing` forever — and the UI would show a spinner or
    /// a black screen with no indication of what went wrong.
    public func markFailed(message: String) async {
        let failedState = PlaybackState(
            status: .failed,
            item: state.item,
            position: state.position,
            duration: state.duration,
            error: message
        )
        resumeTask?.cancel()
        resumeTask = nil
        await teardownPlayer()
        state = failedState
    }

    // MARK: - Player vending

    /// Returns the underlying `AVPlayer` for SwiftUI `VideoPlayer` to render.
    ///
    /// Called from a `@MainActor` view model. The `AVPlayer` class is `Sendable`,
    /// and all of its methods that we care about are `@MainActor` — so passing
    /// the reference back to MainActor is correct.
    public func currentAVPlayer() async -> AVPlayer? {
        avPlayer
    }

    // MARK: - Internals

    private func startResumeLoop() {
        resumeTask?.cancel()
        let interval = resumeWriteInterval
        resumeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                await self.tickResume()
            }
        }
    }

    private func tickResume() async {
        guard state.status == .playing else { return }
        await writeResumeNow()
    }

    private func writeResumeNow() async {
        guard let item = state.item, let player = avPlayer else { return }
        let seconds = await MainActor.run { player.currentTime().seconds }
        guard seconds.isFinite, !seconds.isNaN else { return }
        let position = Duration.seconds(seconds)
        state.position = position
        await resumeStore.record(.init(mediaID: item.id, position: position))
    }

    private func currentPlaybackSeconds() async -> Double {
        if let avPlayer {
            let seconds = await MainActor.run { avPlayer.currentTime().seconds }
            if seconds.isFinite, !seconds.isNaN {
                return seconds
            }
        }
        return Self.durationSeconds(state.position)
    }

    private func persistedResumeSeconds(for id: MediaID) async -> Double {
        guard let point = await resumeStore.point(for: id) else { return 0 }
        return Self.durationSeconds(point.position)
    }

    private func teardownPlayer() async {
        guard let player = avPlayer else { return }
        await MainActor.run {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        avPlayer = nil
    }

    // MARK: - Helpers

    static func durationSeconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
