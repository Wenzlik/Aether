import Foundation
import AVFoundation
import os
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

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
    private var sceneObservers: [Task<Void, Never>] = []

    /// The source that resolves fresh playback URLs. Set on `prepare(...)` and
    /// reused by `recoverOrFail`. `nil` falls back to the item's own
    /// `streamURL` (tests / sources with no resolver).
    private var source: (any MediaSource)?

    /// The server transcode session currently driving playback, so we can stop
    /// it on teardown / after a track switch. `nil` for direct play.
    private var activeTranscodeSessionID: String?

    /// Decision mode from the last resolved playback — `.directPlay` means we
    /// can switch tracks live via `AVMediaSelection`; transcode/directStream
    /// requires a stream restart to rebake the track selection.
    private var currentDecision: PlaybackDecisionMode?

    // MARK: - Diagnostics

    /// Structured playback-lifecycle logging — to settle whether failures live
    /// in this shared layer or the source layer. Visible in Console.app /
    /// `log stream --predicate 'subsystem == "cz.zmrhal.aether"'`. **Never logs
    /// tokens or full URLs** — only a stable one-way hash of the URL so you can
    /// tell whether two attempts used the same stream.
    private static let log = Logger(subsystem: "cz.zmrhal.aether", category: "playback")

    /// Monotonic "Playback Attempt #N" counter for the current process.
    private var attempt = 0

    /// Auto-recovery budget for a mid-stream failure (e.g. the server reaped a
    /// paused / idle transcode session). One automatic retry per user-initiated
    /// open: a recovery that immediately fails again gives up (rather than
    /// looping) and surfaces the error, where the user's Retry re-opens and
    /// re-arms the budget.
    private var recoveryAttempts = 0
    private static let maxRecoveryAttempts = 1

    /// djb2 hash of a string — stable within a run, one-way (token-safe).
    nonisolated static func urlHash(_ url: URL?) -> String {
        guard let url else { return "nil" }
        var hash: UInt64 = 5381
        for byte in url.absoluteString.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return String(hash, radix: 16)
    }

    nonisolated static func shortID(_ object: AnyObject?) -> String {
        guard let object else { return "nil" }
        return String(UInt(bitPattern: ObjectIdentifier(object).hashValue) & 0xFFFFFF, radix: 16)
    }

    // NOTE: there is deliberately NO "base offset" added to `currentTime()`.
    // Earlier code assumed a Plex transcode started at an offset emits an HLS
    // timeline whose zero is the offset, and added the offset back when
    // recording resume / reporting position. In practice `AVPlayer.currentTime()`
    // for the universal transcoder is the *absolute* content time on every path
    // — direct play, client-seek, and a server-baked offset alike — so adding
    // the offset double-counted and made resume run away (1h → 2.5h → 5h on a
    // 2h film, which then broke "Resume"). Position now comes straight from
    // `currentTime()`, clamped to the content duration. `ResolvedPlayback`
    // still reports the baked offset, but only the URL builder uses it.

    /// Optional offline catalogue. When set, `prepare(item:source:startAt:)`
    /// checks for a completed download before asking the source for a
    /// network URL — so a downloaded title plays from `Caches/` even when
    /// the user is online. `nil` keeps the legacy "always go through the
    /// source" path (used by tests / sources without a downloads pipeline).
    private var downloadStore: DownloadStore?

    public init(resumeStore: ResumeStore, resumeWriteInterval: Duration = .seconds(5)) {
        self.state = PlaybackState()
        self.resumeStore = resumeStore
        self.resumeWriteInterval = resumeWriteInterval
        Task { await self.startSceneObserver() }
    }

    /// Attach the downloads catalogue so prepare can intercept items that
    /// already exist on disk. Idempotent — `AppSession.start()` calls this
    /// after the store is initialised.
    public func attachDownloadStore(_ store: DownloadStore) {
        self.downloadStore = store
    }

    private func startSceneObserver() {
        #if canImport(UIKit)
        sceneObservers = [
            Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: UIApplication.didEnterBackgroundNotification) {
                    await self?.setActive(false)
                }
            },
            Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: UIApplication.willEnterForegroundNotification) {
                    await self?.setActive(true)
                }
            }
        ]
        #elseif canImport(AppKit)
        sceneObservers = [
            Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: NSApplication.didResignActiveNotification) {
                    await self?.setActive(false)
                }
            },
            Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                    await self?.setActive(true)
                }
            }
        ]
        #endif
    }

    // MARK: - Commands

    /// Prepare the session for a new item.
    ///
    /// Tears down any previous player, builds a new `AVPlayer`, seeks to the
    /// start position, and starts the resume-write loop. Does *not* auto-play —
    /// call `play()` when the view is ready.
    ///
    /// `startAt` chooses where playback begins:
    /// - `nil` → resume from the persisted point (the default; "Resume").
    /// - an explicit value → start exactly there. Pass `0` for "Play from
    ///   start", which ignores any saved resume point.
    public func prepare(
        item: MediaItem,
        source: (any MediaSource)? = nil,
        startAt explicitStart: Double? = nil,
        isRecovery: Bool = false
    ) async {
        // A user-initiated open re-arms the recovery budget; a recovery re-prepare
        // must not, or it could loop on a permanently broken stream.
        if !isRecovery { recoveryAttempts = 0 }
        attempt += 1
        let startLabel = explicitStart.map { String($0) } ?? "resume"
        Self.log.notice("prepare #\(self.attempt, privacy: .public) item=\(item.id.rawValue, privacy: .public) source=\(item.id.source.stableKey, privacy: .public) startAt=\(startLabel, privacy: .public)")

        // Tear down previous session before starting a new one (stops its
        // transcode session too).
        resumeTask?.cancel()
        resumeTask = nil
        await teardownPlayer()
        self.source = source

        // Show "loading" up front: resolving warms up the transcode (can take a
        // few seconds), and we'd rather sit in loading than flash a failure.
        state = PlaybackState(status: .loading, item: item)

        var resumeSeconds: Double
        if let explicitStart {
            resumeSeconds = explicitStart
        } else {
            resumeSeconds = await persistedResumeSeconds(for: item.id)
        }
        // Guard against a corrupt / out-of-range saved point — e.g. one left over
        // from the pre-fix resume bug that could record a position *beyond* the
        // runtime. A resume past the end would bake a transcode start past EOF
        // (warm-up fails → "Resume" doesn't play) and can't self-heal because no
        // playback ever starts. Treat at/over the runtime as "start over".
        resumeSeconds = Self.sanitizedResume(resumeSeconds, runtime: item.runtime)

        // Offline override: if the item has a completed download on disk,
        // **and** AVPlayer can actually decode it, play from there —
        // no source call, no transcode session, no warm-up. The player
        // gets a `file://` URL and seeks client-side just like any
        // direct-play. Works equally well online and offline; we prefer
        // the local copy in both cases (no point burning the user's
        // bandwidth when they already have the bytes).
        //
        // The `isPlayable` pre-flight is what protects us from MKV / DV
        // / DTS containers that iOS can't decode locally even though
        // Plex would happily transcode them for streaming. Without it
        // the user sees "Cannot Open (AVFoundationErrorDomain -11828)"
        // on Play — same downloaded file that streams fine plays not at
        // all locally. The fallback below transparently goes back to
        // the source layer, so the user gets streaming playback instead
        // of a hard error.
        let resolved: ResolvedPlayback
        let localPlayableURL = await offlinePlayableURL(for: item)
        if let localURL = localPlayableURL {
            resolved = ResolvedPlayback(
                url: localURL,
                isServerTranscode: false,
                baseOffsetSeconds: 0,
                clientSeekSeconds: resumeSeconds > 0 ? resumeSeconds : nil,
                transcodeSessionID: nil,
                decision: .directPlay
            )
            Self.log.notice("offline play #\(self.attempt, privacy: .public) item=\(item.id.rawValue, privacy: .public) file=\(localURL.lastPathComponent, privacy: .public)")
        } else {
            // Resolve a FRESH, warmed-up URL through the source — a new
            // transcode session at the resume offset, confirmed readable.
            // This is what stops a reaped / not-yet-ready Plex session
            // surfacing as NSURLError -1008.
            do {
                resolved = try await resolvePlayback(for: item, startSeconds: resumeSeconds)
            } catch {
                state = PlaybackState(
                    status: .failed,
                    item: item,
                    error: Self.resolveErrorDetail(error)
                )
                return
            }
        }

        activeTranscodeSessionID = resolved.transcodeSessionID
        currentDecision = resolved.decision
        let seekTarget = seekTarget(for: resolved, position: resumeSeconds)
        let url = resolved.url
        let (player, itemID) = await MainActor.run { () -> (AVPlayer, String) in
            let p = AVPlayer(url: url)
            if let seekTarget {
                p.seek(to: CMTime(seconds: seekTarget, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            return (p, Self.shortID(p.currentItem))
        }

        let sessionShort: String = resolved.transcodeSessionID.map { String($0.prefix(8)) } ?? "-"
        let createdLog = "player created #\(attempt) player=\(Self.shortID(player)) item=\(itemID) transcode=\(resolved.isServerTranscode) session=\(sessionShort) urlHash=\(Self.urlHash(url))"
        Self.log.notice("\(createdLog, privacy: .public)")

        self.avPlayer = player
        self.state = PlaybackState(
            status: .loading,
            item: item,
            position: .seconds(resumeSeconds)
        )
        startResumeLoop()

        // Direct play ships the file as-is — the server can't pick a track, so
        // the user's audio / subtitle selection must be applied CLIENT-side via
        // AVMediaSelection (#68: offline `.original` downloads always played
        // the container default). Transcode/direct-stream paths are handled
        // server-side and are left alone. A nil decision with no server
        // transcode (mock / legacy paths) counts as direct play.
        if resolved.decision == .directPlay
            || (resolved.decision == nil && !resolved.isServerTranscode) {
            applyClientSideTrackSelection(item: item, player: player)
        }
    }

    /// Selects the item's chosen audio / subtitle tracks on the player's
    /// media-selection groups, matched by language (then title) via the pure
    /// `MediaSelectionMatcher`. Fire-and-forget: a failed asset load or no
    /// confident match leaves the player's default untouched.
    private nonisolated func applyClientSideTrackSelection(item: MediaItem, player: AVPlayer) {
        let audio = item.selectedAudioTrack
        let subtitle = item.selectedSubtitleTrack
        // No selected track despite available tracks = explicit "Off".
        let subtitlesOff = item.selectedSubtitleTrackID == nil && !item.subtitleTracks.isEmpty
        guard audio != nil || subtitle != nil || subtitlesOff else { return }

        Task { @MainActor in
            guard let playerItem = player.currentItem else { return }
            let asset = playerItem.asset

            if let audio,
               let group = try? await asset.loadMediaSelectionGroup(for: .audible) {
                let options = group.options.map { ($0.extendedLanguageTag, $0.displayName) }
                if let index = MediaSelectionMatcher.bestIndex(
                    language: audio.languageCode, title: audio.title, among: options
                ) {
                    playerItem.select(group.options[index], in: group)
                }
            }

            if let group = try? await asset.loadMediaSelectionGroup(for: .legible) {
                if subtitlesOff {
                    playerItem.select(nil, in: group)
                } else if let subtitle {
                    let options = group.options.map { ($0.extendedLanguageTag, $0.displayName) }
                    if let index = MediaSelectionMatcher.bestIndex(
                        language: subtitle.languageCode, title: subtitle.title, among: options
                    ) {
                        playerItem.select(group.options[index], in: group)
                    }
                }
            }
        }
    }

    /// Where the player should seek after the item is ready: the resolver's
    /// explicit `clientSeekSeconds` (small transcode offset), else the resume
    /// point for direct play. Transcodes with a baked-in offset return `nil`.
    private func seekTarget(for resolved: ResolvedPlayback, position: Double) -> Double? {
        if let explicit = resolved.clientSeekSeconds { return explicit > 0 ? explicit : nil }
        if !resolved.isServerTranscode, position > 0 { return position }
        return nil
    }

    public func play() async {
        guard let avPlayer, state.item != nil else { return }
        Self.log.notice("play #\(self.attempt, privacy: .public)")
        await MainActor.run { avPlayer.play() }
        state.status = .playing
    }

    public func pause() async {
        guard let avPlayer, state.status == .playing else { return }
        Self.log.notice("pause #\(self.attempt, privacy: .public) pos=\(Self.durationSeconds(self.state.position), privacy: .public)s")
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

    /// Seek to an absolute **content** position (seconds). The player timeline is
    /// absolute on every path (see the note by `prepare`), so this is a plain
    /// seek to `target`. Used by Skip Intro / Skip Credits, which work in
    /// absolute content time from the segment data.
    public func skip(toContentSeconds target: Double) async {
        guard let avPlayer else { return }
        let playerSeconds = max(0, target)
        let cmTime = CMTime(seconds: playerSeconds, preferredTimescale: 600)
        await MainActor.run {
            avPlayer.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        state.position = .seconds(target)
    }

    // MARK: - Track switching

    /// Switch to a different audio track during playback.
    ///
    /// - DirectPlay (AVPlayer): applies `AVMediaSelectionOption` live — no
    ///   stream restart needed.
    /// - Transcode / DirectStream: restarts the HLS stream at the current
    ///   position with the new track baked into the URL.
    public func switchAudioTrack(_ track: MediaAudioTrack) async {
        guard let item = state.item else { return }
        let position = await currentPositionSeconds()
        let newItem = item.selectingAudioTrack(track)
        if currentDecision == .directPlay, let avPlayer {
            state.item = newItem
            applyClientSideTrackSelection(item: newItem, player: avPlayer)
            return
        }
        await prepare(item: newItem, source: source, startAt: position, isRecovery: true)
        if state.status != .failed { await play() }
    }

    /// Switch to a different subtitle track (or turn subtitles off with `nil`).
    ///
    /// Uses the same directPlay / restart logic as `switchAudioTrack`.
    public func switchSubtitleTrack(_ track: MediaSubtitleTrack?) async {
        guard let item = state.item else { return }
        let position = await currentPositionSeconds()
        let newItem = item.selectingSubtitleTrack(track)
        if currentDecision == .directPlay, let avPlayer {
            state.item = newItem
            applyClientSideTrackSelection(item: newItem, player: avPlayer)
            return
        }
        await prepare(item: newItem, source: source, startAt: position, isRecovery: true)
        if state.status != .failed { await play() }
    }

    /// The live absolute content position in seconds — fresh on demand (the
    /// resume loop only writes every few seconds, too coarse for the skip
    /// buttons). Falls back to the last recorded `state.position`.
    public func currentPositionSeconds() async -> Double {
        guard let avPlayer else { return Self.durationSeconds(state.position) }
        let elapsed = await MainActor.run { avPlayer.currentTime().seconds }
        guard elapsed.isFinite, !elapsed.isNaN else { return Self.durationSeconds(state.position) }
        return elapsed
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
    /// Called by the view model when it observes an `AVPlayerItem` failure.
    /// Attempts **one** automatic recovery — re-resolve a fresh, warmed URL at
    /// the last position and resume — before surfacing the error. This is what
    /// recovers from a paused/idle stream whose server-side transcode session
    /// was reaped (the cross-source "pause → wait → fail" case): the native
    /// transport drives `AVPlayer` directly, so without this there's no hook to
    /// rebuild the stream on resume.
    public func recoverOrFail(message: String) async {
        // A load / recovery is already in flight — let it settle.
        if state.status == .loading { return }
        guard let source, let item = state.item, recoveryAttempts < Self.maxRecoveryAttempts else {
            await markFailed(message: message)
            return
        }
        recoveryAttempts += 1
        let position = Self.durationSeconds(state.position)
        Self.log.notice("auto-recover #\(self.attempt, privacy: .public) (try \(self.recoveryAttempts, privacy: .public)) at \(position, privacy: .public)s after: \(message, privacy: .public)")
        await prepare(item: item, source: source, startAt: position, isRecovery: true)
        if state.status != .failed {
            await play()
        }
    }

    public func markFailed(message: String) async {
        Self.log.error("playback FAILED #\(self.attempt, privacy: .public) status=\(String(describing: self.state.status), privacy: .public) pos=\(Self.durationSeconds(self.state.position), privacy: .public)s reason=\(message, privacy: .public)")
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

    /// Resolve a fresh playback URL for `item` at `startSeconds`. Routes through
    /// the source's resolver when we have one (Plex mints a new transcode
    /// session); falls back to the item's own `streamURL` otherwise (tests and
    /// sources without a resolver).
    private func resolvePlayback(for item: MediaItem, startSeconds: Double) async throws -> ResolvedPlayback {
        let startTime: Duration? = startSeconds > 0 ? .seconds(startSeconds) : nil
        let request = PlaybackRequest(item: item, startTime: startTime)

        if let source {
            return try await source.resolvePlayback(request)
        }

        // No source: legacy direct path. We can no longer mutate URLs to bake
        // an offset, so transcodes fall back to client-side seeking — fine for
        // tests / Mock; the real Plex path always has a `source` to resolve
        // through. Direct-play already seeks client-side.
        guard let url = item.streamURL else {
            throw PlaybackResolveError.noPlayableStream
        }
        return ResolvedPlayback(
            url: url,
            isServerTranscode: item.isServerTranscode,
            baseOffsetSeconds: 0,
            clientSeekSeconds: startSeconds > 0 ? startSeconds : nil
        )
    }

    /// Developer-facing detail for a resolve failure (kept in `state.error`,
    /// surfaced only behind the player's Details disclosure — the user sees a
    /// friendly message, not this).
    private static func resolveErrorDetail(_ error: any Error) -> String {
        switch error {
        case PlaybackResolveError.noPlayableStream:
            return "No playable stream — the server didn't return a usable Part or connection."
        case let PlaybackResolveError.notReady(diagnostics):
            return diagnostics
        default:
            return "Couldn't resolve a playback URL: \(error)"
        }
    }

    /// Suspend/resume background work with the app's foreground state (driven
    /// from the view layer's `scenePhase`). On background we cancel the periodic
    /// resume loop — after writing one final resume point so the position is
    /// captured — rather than waking the CPU every few seconds behind the lock
    /// screen; on foreground the loop restarts. Background audio keeps playing
    /// either way. (`resumeTask` is private to the session, so the view model's
    /// poll-gating couldn't reach it — this closes that gap.)
    public func setActive(_ isActive: Bool) async {
        if isActive {
            guard avPlayer != nil, resumeTask == nil else { return }
            startResumeLoop()
        } else {
            resumeTask?.cancel()
            resumeTask = nil
            await writeResumeNow()
        }
    }

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
        let (elapsed, durationSeconds) = await MainActor.run {
            (player.currentTime().seconds, player.currentItem?.duration.seconds ?? .nan)
        }
        guard elapsed.isFinite, !elapsed.isNaN else { return }
        // The player timeline is absolute (see the note by `prepare`), so the
        // content position is `currentTime()` directly. Clamp to the duration so
        // a bad reading can never persist a resume point beyond the runtime —
        // an over-the-end resume is exactly what broke "Resume" before.
        var seconds = max(0, elapsed)
        if durationSeconds.isFinite, durationSeconds > 0 {
            seconds = min(seconds, durationSeconds)
        }
        let position = Duration.seconds(seconds)
        state.position = position
        await resumeStore.record(.init(mediaID: item.id, position: position))
        // Report the playhead to the server too (Plex timeline / Jellyfin
        // Sessions), so resume syncs across clients and devices — not just the
        // local store. Best-effort + non-throwing (no-op for sources without
        // server play state). Rides the same ~5s cadence as the local write.
        let serverDuration = durationSeconds.isFinite && durationSeconds > 0
            ? Duration.seconds(durationSeconds) : nil
        await source?.recordProgress(
            item.id, position: position, duration: serverDuration,
            paused: state.status != .playing
        )
    }

    /// Return the local file URL for `item` **only if AVPlayer can decode
    /// it**. The on-disk file existing isn't enough — Plex's raw Part
    /// download may be an MKV with HEVC 10-bit + Dolby Vision (and / or
    /// DTS / TrueHD audio) which iOS recognises as a container but
    /// can't decode. In that case we want playback to fall back to the
    /// server's HLS transcode, which iOS *can* play.
    ///
    /// `AVURLAsset.load(.isPlayable)` is the supported way to ask
    /// AVFoundation up-front. It's a fast metadata probe (no decode);
    /// the call returns once headers + first sample tables are read.
    /// Returns `nil` when the file doesn't exist, isn't recorded, or
    /// fails the probe.
    private func offlinePlayableURL(for item: MediaItem) async -> URL? {
        guard let store = downloadStore else { return nil }
        // `existingLocalURL()` re-bases a stale absolute path (changed data-
        // container UUID) onto the current downloads dir, so a present-but-moved
        // file still plays locally instead of falling through to the server.
        guard let localURL = await store.status(for: item.id).existingLocalURL() else { return nil }
        let asset = AVURLAsset(url: localURL)
        let isPlayable: Bool
        do {
            isPlayable = try await asset.load(.isPlayable)
        } catch {
            Self.log.error("offline isPlayable probe failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        guard isPlayable else {
            Self.log.notice("offline file present but not playable (codec / container unsupported); falling back to streaming")
            return nil
        }
        return localURL
    }

    private func persistedResumeSeconds(for id: MediaID) async -> Double {
        guard let point = await resumeStore.point(for: id) else { return 0 }
        return Self.durationSeconds(point.position)
    }

    private func teardownPlayer() async {
        // Stop the server transcode session so Plex frees it immediately rather
        // than reaping it later (and so a stale one can't linger).
        if let sessionID = activeTranscodeSessionID {
            activeTranscodeSessionID = nil
            await source?.stopTranscode(sessionID: sessionID)
        }
        guard let player = avPlayer else { return }
        Self.log.notice("teardown #\(self.attempt, privacy: .public) player=\(Self.shortID(player), privacy: .public)")
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

    /// Clamp a resume position to a sane range for `runtime`. A non-finite or
    /// non-positive value, or one at/beyond the runtime (corrupt data, or a
    /// title watched to the end), resets to `0` ("start over") — resuming past
    /// the end would bake a transcode start past EOF and fail to play.
    static func sanitizedResume(_ seconds: Double, runtime: Duration?) -> Double {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        if let runtime {
            let total = durationSeconds(runtime)
            if total > 0, seconds >= total { return 0 }
        }
        return seconds
    }
}
