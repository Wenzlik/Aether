import SwiftUI
import VLCKit

/// One audio / subtitle track choice. `id` is VLCKit's track *index* (the value
/// `currentAudioTrackIndex` / `currentVideoSubTitleIndex` take); `-1` is Disable.
struct TrackOption: Identifiable, Hashable {
    let id: Int
    let name: String
}

/// Owns the `VLCMediaPlayer` for one player window and exposes observable state
/// the SwiftUI controls bind to (IINA-style). Uses VLCKit **3.x** (the macOS
/// build with a working video output) — its track API is index-based, unlike
/// VLCKit 4's `audioTracks`/`textTracks`.
///
/// State is polled on a main-actor timer rather than via `VLCMediaPlayerDelegate`
/// (VLCKit fires those off the main thread). Playback starts only once the media
/// is set AND the video view is in a window (its GL surface is ready).
@MainActor
@Observable
final class MacPlayerModel {
    let player = VLCMediaPlayer()

    private(set) var isPlaying = false
    /// 0…1 playhead. Bound to the scrubber; while the user drags, `isScrubbing`
    /// suspends time-driven updates.
    var position: Double = 0
    var isScrubbing = false
    private(set) var timeText = "0:00"
    private(set) var durationText = "0:00"
    var volume: Double = 100 { didSet { player.audio?.volume = Int32(volume) } }
    private(set) var audioTracks: [TrackOption] = []
    private(set) var subtitleTracks: [TrackOption] = []
    private(set) var currentAudioID = -1
    private(set) var currentSubtitleID = -1
    private(set) var title = ""

    @ObservationIgnored private var tickTask: Task<Void, Never>?
    private var loadedURL: URL?
    private var mediaReady = false
    private var viewReady = false
    private var started = false

    deinit { tickTask?.cancel() }

    func load(_ url: URL) {
        guard url != loadedURL else { return }
        loadedURL = url
        title = url.deletingPathExtension().lastPathComponent
        player.media = VLCMedia(url: url)   // VLCKit 3: non-optional
        mediaReady = true
        playIfReady()
    }

    /// Called by the video view once attached to a window (GL surface ready).
    func markViewReady() {
        viewReady = true
        playIfReady()
    }

    private func playIfReady() {
        guard mediaReady, viewReady, !started else { return }
        started = true
        player.play()
        startTicker()
    }

    // MARK: Transport

    /// Stop playback + polling — called when the player window closes, so audio
    /// doesn't keep playing after the view is gone.
    func stop() {
        player.stop()
        tickTask?.cancel()
        tickTask = nil
    }

    func togglePlay() { player.isPlaying ? player.pause() : player.play() }
    func skipBackward() { player.jumpBackward(10) }
    func skipForward() { player.jumpForward(10) }
    func commitSeek() { player.position = Float(max(0, min(1, position))) }

    // MARK: Tracks (VLCKit 3 — index based)

    func selectAudio(id: Int) { player.currentAudioTrackIndex = Int32(id) }
    func selectSubtitle(id: Int) { player.currentVideoSubTitleIndex = Int32(id) }

    // MARK: Polling

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
        if !isScrubbing { position = Double(player.position) }
        timeText = player.time.stringValue ?? "0:00"
        durationText = player.media?.length.stringValue ?? player.time.stringValue ?? "0:00"
        currentAudioID = Int(player.currentAudioTrackIndex)
        currentSubtitleID = Int(player.currentVideoSubTitleIndex)
        let audio = Self.options(player.audioTrackIndexes, player.audioTrackNames)
        if audio != audioTracks { audioTracks = audio }
        let subs = Self.options(player.videoSubTitlesIndexes, player.videoSubTitlesNames)
        if subs != subtitleTracks { subtitleTracks = subs }
    }

    /// Zip VLCKit's parallel `…Indexes` / `…Names` arrays into `TrackOption`s.
    private static func options(_ indexes: [Any]?, _ names: [Any]?) -> [TrackOption] {
        guard let indexes, let names, indexes.count == names.count else { return [] }
        return zip(indexes, names).map { idx, name in
            TrackOption(id: (idx as? NSNumber)?.intValue ?? -1, name: name as? String ?? "Track")
        }
    }
}
