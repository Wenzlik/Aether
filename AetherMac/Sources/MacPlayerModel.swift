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
    // `--avcodec-hw=none` at the libvlc instance level (a media option was
    // ignored — frames stayed NV12). Forces software decode (I420) to test
    // whether VLCKit's macOS GL vout assert is tied to the VideoToolbox NV12
    // path or is a vout bug regardless of format.
    let player = VLCMediaPlayer(options: ["--avcodec-hw=none"])

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
        if let media = VLCMedia(url: url) {
            // Force software decode. VideoToolbox HW frames are NV12, and VLCKit's
            // macOS OpenGL vout asserts compiling/using the NV12 conversion path
            // (GL_INVALID_OPERATION / GL_INVALID_FRAMEBUFFER_OPERATION). Software
            // decode yields I420, which uses VLC's well-trodden GL path.
            media.addOption(":avcodec-hw=none")
            player.media = media
        }
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
    /// Pass `nil` to turn subtitles off. Uses VLCKit 4's dedicated text-track
    /// API — `isSelectedExclusively` (fine for audio) doesn't reliably enable the
    /// SPU, so subtitle selection appeared to do nothing.
    func selectSubtitle(_ track: VLCMediaPlayer.Track?) {
        if let track { player.selectTextTracks([track]) }
        else { player.deselectAllTextTracks() }
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
