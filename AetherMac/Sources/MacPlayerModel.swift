import SwiftUI
import AetherCore
import IOKit.pwr_mgt

/// One audio / subtitle track choice. `id` is mpv's track id (the value `aid` /
/// `sid` take); `-1` means Disable ("no").
struct TrackOption: Identifiable, Hashable {
    let id: Int
    let name: String
}

/// Owns the libmpv player for one player window and exposes observable state the
/// SwiftUI controls bind to (IINA-style). The macOS engine is **libmpv** (the
/// engine behind IINA) — best-in-class HW decode, HDR, and subtitle rendering —
/// replacing the older VLCKit path (#232). Property changes arrive via
/// `MpvClient`'s wakeup→drain on the main actor, so all state stays on main.
@MainActor
@Observable
final class MacPlayerModel {
    @ObservationIgnored let mpv = MpvClient()
    @ObservationIgnored private var sleepAssertionID: IOPMAssertionID = 0

    private(set) var isPlaying = false { didSet { updateSleepAssertion() } }
    /// 0…1 playhead. Bound to the scrubber; while the user drags, `isScrubbing`
    /// suspends time-driven updates.
    var position: Double = 0
    var isScrubbing = false
    private(set) var timeText = "0:00"
    private(set) var durationText = "0:00"
    var volume: Double = 100 { didSet { mpv.setProperty("volume", String(Int(volume))) } }
    private(set) var audioTracks: [TrackOption] = []
    private(set) var subtitleTracks: [TrackOption] = []
    private(set) var currentAudioID = -1
    private(set) var currentSubtitleID = -1
    private(set) var title = ""

    private var loadedURL: URL?
    private var durationSeconds: Double = 0

    // Resume tracking (server items only — local files carry no `item`).
    @ObservationIgnored private var session: MacSession?
    @ObservationIgnored private var item: MediaItem?
    private var pendingResumeSeconds: Double?
    private var didSeekResume = false
    private var lastRecordedSecond = -10
    /// Latest playhead from time-pos events — used at teardown so we never call
    /// the (potentially blocking) mpv_get_property on a stalled network stream.
    private var lastKnownSeconds: Double = 0
    private var didMarkWatched = false

    // Skip segments + Auto-Play-Next (server items only).
    @ObservationIgnored private var segments: [PlaybackSegment] = []
    @ObservationIgnored private var prefs: PlaybackPreferencesStore?
    /// The next episode after this one, when there is one — drives Auto-Play-Next.
    private(set) var nextItem: MediaItem?
    /// The intro/recap or credits segment under the playhead while its Skip mode
    /// is `.button` — drives the floating "Skip Intro" / "Skip Credits" button.
    private(set) var activeSkip: PlaybackSegment?
    /// Seconds left on the Up Next countdown; `nil` = no prompt showing.
    private(set) var upNextRemaining: Int?
    @ObservationIgnored private var autoSkipped: Set<String> = []
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var didFinish = false
    /// Set by the player screen: advance to the next episode (swaps the window's
    /// playback URL) and close (finished with no next / Auto-Play-Next off).
    @ObservationIgnored var onAdvance: ((MediaItem) -> Void)?
    @ObservationIgnored var onFinished: (() -> Void)?

    func load(_ url: URL, session: MacSession? = nil, item: MediaItem? = nil) {
        guard url != loadedURL else { return }
        loadedURL = url
        self.session = session
        self.item = item
        self.prefs = session?.playbackPrefs
        title = item?.displayTitle ?? Self.displayTitle(for: url)
        // Reset per-title playback state (the screen reuses one model across
        // Auto-Play-Next episodes).
        didFinish = false
        didMarkWatched = false
        didSeekResume = false
        autoSkipped = []
        segments = []
        nextItem = nil
        activeSkip = nil
        cancelCountdown()

        mpv.onPropertyChange = { [weak self] name in self?.handleProperty(name) }
        mpv.onEndFile = { [weak self] in self?.handleEndOfFile() }
        // mpv is already created + initialized in MpvClient.init (so the render
        // context can attach); here we just point it at the file.
        mpv.loadFile(url)

        if let item, let session {
            Task { [weak self] in
                let seconds = await session.startSeconds(for: item)
                self?.pendingResumeSeconds = seconds
            }
            // Skip segments + the next episode, for the Skip buttons + Auto-Play-Next.
            Task { [weak self] in
                let segs = await session.segments(for: item)
                let next = await session.nextEpisode(after: item)
                self?.segments = segs
                self?.nextItem = next
            }
        }
    }

    // MARK: Transport

    /// Stop playback — called when the inline player closes. Commits a final
    /// resume point, then tears mpv down deterministically (render context freed
    /// first, then the handle) on the main thread, so audio stops immediately and
    /// nothing leaks. `destroy()` is idempotent; a late `draw` no-ops safely.
    func stop() {
        recordResume(committing: true)
        mpv.destroy()
    }

    func togglePlay() { mpv.command(["cycle", "pause"]) }
    func skipBackward() { mpv.command(["seek", "-10", "relative"]) }
    func skipForward() { mpv.command(["seek", "10", "relative"]) }
    func commitSeek() {
        guard durationSeconds > 0 else { return }
        let seconds = max(0, min(1, position)) * durationSeconds
        mpv.command(["seek", String(seconds), "absolute"])
    }

    // MARK: Tracks

    func selectAudio(id: Int) { mpv.setProperty("aid", id < 0 ? "no" : String(id)) }
    func selectSubtitle(id: Int) { mpv.setProperty("sid", id < 0 ? "no" : String(id)) }

    // MARK: Display sleep prevention

    private func updateSleepAssertion() {
        if isPlaying {
            guard sleepAssertionID == 0 else { return }
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypeNoDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Aether video playback" as CFString,
                &sleepAssertionID
            )
        } else {
            guard sleepAssertionID != 0 else { return }
            IOPMAssertionRelease(sleepAssertionID)
            sleepAssertionID = 0
        }
    }

    // MARK: Property changes (from mpv, on main)

    private func handleProperty(_ name: String) {
        switch name {
        case "pause":
            isPlaying = !mpv.boolProperty("pause")
        case "duration":
            durationSeconds = mpv.doubleProperty("duration")
            durationText = Self.format(durationSeconds)
            applyPendingResume()
        case "time-pos":
            let seconds = mpv.doubleProperty("time-pos")
            lastKnownSeconds = seconds          // cached for teardown (see below)
            timeText = Self.format(seconds)
            if !isScrubbing, durationSeconds > 0 {
                position = max(0, min(1, seconds / durationSeconds))
            }
            applyPendingResume()
            maybeRecord(seconds: seconds)
            maybeMarkWatched()
            updateSkipAndAutoplay(seconds: seconds)
        case "aid":
            currentAudioID = mpv.stringProperty("aid").flatMap(Int.init) ?? -1
        case "sid":
            currentSubtitleID = mpv.stringProperty("sid").flatMap(Int.init) ?? -1
        case "track-list/count":
            reloadTracks()
        default:
            break
        }
    }

    private func reloadTracks() {
        let count = Int(mpv.intProperty("track-list/count"))
        guard count >= 0 else { return }
        var audio: [TrackOption] = []
        var subs: [TrackOption] = [TrackOption(id: -1, name: "Off")]
        for i in 0..<count {
            let type = mpv.stringProperty("track-list/\(i)/type")
            let id = Int(mpv.intProperty("track-list/\(i)/id"))
            let lang = mpv.stringProperty("track-list/\(i)/lang")
            let titleStr = mpv.stringProperty("track-list/\(i)/title")
            let name = [titleStr, lang.map { $0.uppercased() }].compactMap { $0 }.first ?? "Track \(id)"
            switch type {
            case "audio": audio.append(TrackOption(id: id, name: name))
            case "sub":   subs.append(TrackOption(id: id, name: name))
            default:      break
            }
        }
        if audio != audioTracks { audioTracks = audio }
        if subs != subtitleTracks { subtitleTracks = subs }
    }

    // MARK: Resume

    private func applyPendingResume() {
        guard !didSeekResume, let resume = pendingResumeSeconds, durationSeconds > 0 else { return }
        didSeekResume = true
        pendingResumeSeconds = nil
        if resume > 1 { mpv.command(["seek", String(resume), "absolute"]) }
    }

    private func maybeRecord(seconds: Double) {
        let nowSecond = Int(seconds)
        guard isPlaying, nowSecond - lastRecordedSecond >= 5 else { return }
        lastRecordedSecond = nowSecond
        recordResume(committing: false)
    }

    /// Once the playhead passes ~90%, mark the title watched on its source
    /// (Plex scrobble / Jellyfin PlayedItems) — once per session.
    private func maybeMarkWatched() {
        guard !didMarkWatched, let item, let session, durationSeconds > 0 else { return }
        guard lastKnownSeconds / durationSeconds >= 0.9 else { return }
        didMarkWatched = true
        Task { await session.markWatched(item) }
    }

    /// Persist the current playhead for Continue Watching. Skips the very start
    /// and the tail (a near-finished title shouldn't reappear as "resume").
    ///
    /// Uses the **cached** `lastKnownSeconds`, never `mpv_get_property` — that
    /// call goes through mpv's dispatch lock and blocks until the core services
    /// it, which on a stalled network stream (Plex) froze the main thread when
    /// recording on stop. The cache is updated from time-pos events (pushed by
    /// the core while it's responsive), so teardown touches no mpv API.
    private func recordResume(committing: Bool) {
        guard let item, let session, durationSeconds > 0 else { return }
        let fraction = lastKnownSeconds / durationSeconds
        // On a committing write (pause / close / stop) near the end or once the
        // title is watched, drop the resume point instead of saving one — so
        // closing a second before the end doesn't leave a "continue" entry that
        // resumes 21:59 of 22:00 (the earlier 5s tick had recorded one).
        if committing, fraction >= 0.9 || didMarkWatched {
            Task { await session.clearResume(for: item) }
            return
        }
        guard fraction > 0.01, fraction < 0.95 else { return }
        let duration = durationSeconds
        let paused = !isPlaying
        Task {
            await session.recordResume(
                for: item, seconds: lastKnownSeconds, committing: committing,
                durationSeconds: duration, paused: paused
            )
        }
    }

    // MARK: Skip segments + Auto-Play-Next

    /// Drive the Skip Intro / Skip Credits button, auto-skip, and the Up Next
    /// countdown off the playhead — called on every time-pos tick.
    private func updateSkipAndAutoplay(seconds: Double) {
        guard let prefs else { activeSkip = nil; return }
        let intro = prefs.skipIntro != .off ? segments.introSegment(at: seconds) : nil
        let credits = prefs.skipCredits != .off ? segments.creditsSegment(at: seconds) : nil

        // Auto-skip the intro the moment it starts (once).
        if prefs.skipIntro == .automatically, let intro, !autoSkipped.contains(intro.id) {
            autoSkipped.insert(intro.id)
            mpv.command(["seek", String(intro.end), "absolute"])
            activeSkip = nil
            return
        }

        if let credits {
            // Auto-Play-Next owns the credits region: run the Up Next countdown
            // rather than skipping (skipping would lose the watched write-back).
            if prefs.autoPlayNext, nextItem != nil {
                if upNextRemaining == nil { startCountdown() }
                activeSkip = prefs.skipCredits == .button ? credits : nil
                return
            }
            // No advance: auto-finish at terminal credits, else auto-skip past.
            if prefs.skipCredits == .automatically, !autoSkipped.contains(credits.id) {
                autoSkipped.insert(credits.id)
                if isTerminal(credits) { finish(); return }
                mpv.command(["seek", String(credits.end), "absolute"])
                activeSkip = nil
                return
            }
        } else {
            cancelCountdown()
        }

        // Button mode: surface whichever segment is active.
        activeSkip = (prefs.skipIntro == .button ? intro : nil)
            ?? (prefs.skipCredits == .button ? credits : nil)
    }

    /// The floating Skip button was tapped — skip the segment, or for terminal
    /// credits with Auto-Play-Next on, jump straight to the next episode.
    func skipActiveSegment() {
        guard let seg = activeSkip else { return }
        activeSkip = nil
        if seg.kind == .credits {
            if prefs?.autoPlayNext == true, nextItem != nil { Task { await playNext() }; return }
            if isTerminal(seg) { finish(); return }
        }
        mpv.command(["seek", String(seg.end), "absolute"])
    }

    /// Whether a segment runs to (within 5s of) the end — terminal credits.
    private func isTerminal(_ seg: PlaybackSegment) -> Bool {
        guard durationSeconds > 0 else { return true }
        return seg.end >= durationSeconds - 5
    }

    private func startCountdown() {
        let total = prefs?.nextEpisodeCountdown ?? 10
        upNextRemaining = total
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            var remaining = total
            while remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                remaining -= 1
                self?.upNextRemaining = remaining
            }
            await self?.playNext()
        }
    }

    /// Dismiss the Up Next prompt (Dismiss button / left the credits region).
    func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        upNextRemaining = nil
    }

    /// Natural end-of-file: advance to the next episode, or finish in place.
    private func handleEndOfFile() {
        isPlaying = false
        finish()
    }

    /// End-of-playback handoff: Auto-Play-Next advances (which marks the finished
    /// episode watched + clears its resume); otherwise mark watched, drop the
    /// resume point, and close.
    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        if prefs?.autoPlayNext == true, nextItem != nil {
            Task { await playNext() }
        } else {
            if let item, let session {
                Task { await session.markWatched(item); await session.clearResume(for: item) }
            }
            onFinished?()
        }
    }

    /// Advance to the next episode in place: mark the finished one watched, drop
    /// its resume point, then hand the next episode to the screen to play.
    func playNext() async {
        guard let next = nextItem, let session else { return }
        cancelCountdown()
        didFinish = true
        if let item {
            await session.markWatched(item)
            await session.clearResume(for: item)
        }
        nextItem = nil
        onAdvance?(next)
    }

    // MARK: Helpers

    /// `H:MM:SS` / `M:SS` for a duration in seconds.
    private static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// A human title for the window — the local filename, but **blank** for a
    /// server stream whose URL filename is a transcode placeholder (`start.m3u8`,
    /// `master.m3u8`, …). Showing "start" was worse than showing nothing.
    private static func displayTitle(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        let placeholders: Set<String> = ["start", "master", "index", "live", "playlist", "stream"]
        if url.pathExtension.lowercased() == "m3u8" || placeholders.contains(name.lowercased()) {
            return ""
        }
        return name
    }
}
