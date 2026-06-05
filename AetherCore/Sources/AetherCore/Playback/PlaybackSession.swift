import Foundation
import AVFoundation
import os

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

    /// The source that resolves fresh playback URLs. Set on `prepare(...)` and
    /// reused by `recoverOrFail`. `nil` falls back to the item's own
    /// `streamURL` (tests / sources with no resolver).
    private var source: (any MediaSource)?

    /// The server transcode session currently driving playback, so we can stop
    /// it on teardown / after a track switch. `nil` for direct play.
    private var activeTranscodeSessionID: String?

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

    /// Content seconds represented by the player's `currentTime() == 0`.
    ///
    /// A Plex transcode started at `offset` emits a fresh HLS timeline whose
    /// zero is the offset point, so `currentTime()` is *relative* to the start
    /// of playback, not absolute. We add this base back when recording resume
    /// points and reporting position. Always `0` for direct-play (the player
    /// seeks to the absolute time, so `currentTime()` is already absolute).
    private var baseOffsetSeconds: Double = 0

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
    }

    /// Attach the downloads catalogue so prepare can intercept items that
    /// already exist on disk. Idempotent — `AppSession.start()` calls this
    /// after the store is initialised.
    public func attachDownloadStore(_ store: DownloadStore) {
        self.downloadStore = store
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

        let resumeSeconds: Double
        if let explicitStart {
            resumeSeconds = explicitStart
        } else {
            resumeSeconds = await persistedResumeSeconds(for: item.id)
        }

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
        baseOffsetSeconds = resolved.baseOffsetSeconds
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

    /// Seek to an absolute **content** position (seconds), accounting for the
    /// transcode base offset — `AVPlayer.currentTime()` is relative to the
    /// transcode start, so the player target is `content − base`. Used by Skip
    /// Intro / Skip Credits, which work in absolute content time from the
    /// segment data. (`base` is 0 for direct play, so this is a plain seek.)
    public func skip(toContentSeconds target: Double) async {
        guard let avPlayer else { return }
        let playerSeconds = max(0, target - baseOffsetSeconds)
        let cmTime = CMTime(seconds: playerSeconds, preferredTimescale: 600)
        await MainActor.run {
            avPlayer.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        state.position = .seconds(target)
    }

    /// The live absolute content position in seconds — fresh on demand (the
    /// resume loop only writes every few seconds, too coarse for the skip
    /// buttons). Falls back to the last recorded `state.position`.
    public func currentPositionSeconds() async -> Double {
        guard let avPlayer else { return Self.durationSeconds(state.position) }
        let elapsed = await MainActor.run { avPlayer.currentTime().seconds }
        guard elapsed.isFinite, !elapsed.isNaN else { return Self.durationSeconds(state.position) }
        return baseOffsetSeconds + elapsed
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
        let elapsed = await MainActor.run { player.currentTime().seconds }
        guard elapsed.isFinite, !elapsed.isNaN else { return }
        // `currentTime()` is relative to the transcode start; add the base to
        // get the absolute content position. `baseOffsetSeconds` is 0 for
        // direct-play, where `currentTime()` is already absolute.
        let position = Duration.seconds(baseOffsetSeconds + elapsed)
        state.position = position
        await resumeStore.record(.init(mediaID: item.id, position: position))
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
        guard case let .completed(localURL, _) = await store.status(for: item.id) else { return nil }
        guard FileManager.default.fileExists(atPath: localURL.path) else { return nil }
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
        baseOffsetSeconds = 0
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
}
