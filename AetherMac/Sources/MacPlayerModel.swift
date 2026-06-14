import SwiftUI
import VLCKit

/// Owns the `VLCMediaPlayer` for one player window and exposes observable state
/// the SwiftUI controls bind to (IINA-style). The view layer never touches VLC
/// directly — it drives this model.
@MainActor
@Observable
final class MacPlayerModel {
    let player = VLCMediaPlayer()

    private(set) var isPlaying = false
    /// 0…1 playhead. Bound to the scrubber; while the user drags, `isScrubbing`
    /// suspends time-driven updates so the thumb doesn't fight the input.
    var position: Double = 0
    var isScrubbing = false
    private(set) var timeText = "0:00"
    private(set) var durationText = "0:00"
    var volume: Double = 100 { didSet { player.audio?.volume = Int32(volume) } }
    private(set) var audioTracks: [VLCMediaPlayer.Track] = []
    private(set) var subtitleTracks: [VLCMediaPlayer.Track] = []
    private(set) var title = ""

    private var delegateProxy: PlayerDelegate?
    private var loadedURL: URL?

    init() {
        player.timeChangeUpdateInterval = 0.25
    }

    func load(_ url: URL) {
        guard url != loadedURL else { return }
        loadedURL = url
        title = url.deletingPathExtension().lastPathComponent
        if delegateProxy == nil {
            let proxy = PlayerDelegate(model: self)
            delegateProxy = proxy
            player.delegate = proxy
        }
        if let media = VLCMedia(url: url) { player.media = media }
        player.play()
    }

    // MARK: Transport

    func togglePlay() { player.isPlaying ? player.pause() : player.play() }
    func skipBackward() { player.jumpBackward(10) }
    func skipForward() { player.jumpForward(10) }
    /// Commit a scrub to the engine (0…1).
    func commitSeek() { player.position = max(0, min(1, position)) }

    // MARK: Tracks

    func selectAudio(_ track: VLCMediaPlayer.Track) {
        track.isSelectedExclusively = true
        refreshTracks()
    }
    /// Pass `nil` to turn subtitles off.
    func selectSubtitle(_ track: VLCMediaPlayer.Track?) {
        if let track { track.isSelectedExclusively = true }
        else { subtitleTracks.forEach { $0.isSelected = false } }
        refreshTracks()
    }
    static func name(for track: VLCMediaPlayer.Track) -> String {
        if !track.trackName.isEmpty { return track.trackName }
        if let language = track.language, !language.isEmpty { return language }
        return "Track"
    }

    // MARK: Delegate hooks (called on the main thread by VLCKit)

    fileprivate func handleTimeChanged() {
        if !isScrubbing { position = player.position }
        timeText = player.time.stringValue ?? "0:00"
        durationText = player.media?.length.stringValue ?? player.time.stringValue ?? "0:00"
    }

    fileprivate func handleStateChanged() {
        isPlaying = player.isPlaying
        refreshTracks()
    }

    private func refreshTracks() {
        audioTracks = player.audioTracks
        subtitleTracks = player.textTracks
    }
}

/// Bridges VLCKit's `NSObject` delegate to the `@Observable` model. VLCKit calls
/// these on the main thread, so `@preconcurrency` lets the MainActor-isolated
/// proxy conform safely.
@MainActor
private final class PlayerDelegate: NSObject, @preconcurrency VLCMediaPlayerDelegate {
    weak var model: MacPlayerModel?
    init(model: MacPlayerModel) { self.model = model }

    func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        model?.handleStateChanged()
    }
    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        model?.handleTimeChanged()
    }
}
