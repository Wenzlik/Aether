import SwiftUI
import VLCKit

/// Owns the `VLCMediaPlayer` for one player window and exposes observable state
/// the SwiftUI controls bind to (IINA-style). The view layer never touches VLC
/// directly — it drives this model.
///
/// State is polled on a main-thread timer (like the iOS player) rather than via
/// `VLCMediaPlayerDelegate`: VLCKit fires delegate callbacks off the main thread
/// on macOS, and touching this `@MainActor` model from there trips the isolation
/// check and crashes (it did, on network playback). Polling sidesteps that.
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

    @ObservationIgnored private var tickTask: Task<Void, Never>?
    private var loadedURL: URL?

    deinit { tickTask?.cancel() }

    func load(_ url: URL) {
        guard url != loadedURL else { return }
        loadedURL = url
        title = url.deletingPathExtension().lastPathComponent
        if let media = VLCMedia(url: url) { player.media = media }
        player.play()
        startTicker()
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
    }
    /// Pass `nil` to turn subtitles off.
    func selectSubtitle(_ track: VLCMediaPlayer.Track?) {
        if let track { track.isSelectedExclusively = true }
        else { subtitleTracks.forEach { $0.isSelected = false } }
    }
    static func name(for track: VLCMediaPlayer.Track) -> String {
        if !track.trackName.isEmpty { return track.trackName }
        if let language = track.language, !language.isEmpty { return language }
        return "Track"
    }

    // MARK: Polling

    /// 0.25s poll of the player's state. The `Task` is created in a `@MainActor`
    /// method, so it inherits MainActor isolation — `tick()` runs on the main
    /// actor, safe to touch this model (and never off a VLC thread).
    private func startTicker() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                self?.tick()
            }
        }
    }

    private func tick() {
        isPlaying = player.isPlaying
        if !isScrubbing { position = player.position }
        timeText = player.time.stringValue
        durationText = player.media?.length.stringValue ?? player.time.stringValue
        let audio = player.audioTracks
        if audio.count != audioTracks.count { audioTracks = audio }
        let text = player.textTracks
        if text.count != subtitleTracks.count { subtitleTracks = text }
    }
}
