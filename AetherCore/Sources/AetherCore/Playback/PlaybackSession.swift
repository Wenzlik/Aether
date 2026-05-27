import Foundation

/// Minimal playback state surfaced to UI.
public struct PlaybackState: Sendable, Equatable {
    public enum Status: Sendable, Equatable { case idle, loading, playing, paused, ended, failed }
    public var status: Status
    public var item: MediaItem?
    public var position: Duration
    public var duration: Duration?

    public init(status: Status = .idle, item: MediaItem? = nil, position: Duration = .zero, duration: Duration? = nil) {
        self.status = status
        self.item = item
        self.position = position
        self.duration = duration
    }
}

/// Owns the single AVPlayer instance and the resume-write loop.
///
/// The real implementation lands in 0.1 Foundation when the AVPlayer prototype is wired up.
/// This stub keeps the surface area stable so views can be built against it.
public actor PlaybackSession {
    public private(set) var state: PlaybackState

    public init() {
        self.state = PlaybackState()
    }

    public func prepare(item: MediaItem) async {
        state = PlaybackState(status: .loading, item: item)
    }

    public func play() async {
        guard state.item != nil else { return }
        state.status = .playing
    }

    public func pause() async {
        guard state.status == .playing else { return }
        state.status = .paused
    }

    public func seek(to position: Duration) async {
        state.position = position
    }

    public func stop() async {
        state = PlaybackState()
    }
}
