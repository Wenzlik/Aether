import Foundation
import os

/// Orchestrates background downloads on a single, shared `URLSession`.
///
/// One instance per app process (URLSession's background identifier is
/// global — two managers fighting over the same identifier corrupts the
/// session). Owns the queue, the URLSession, and the bridge that turns
/// `URLSessionDownloadDelegate` callbacks into actor-safe events.
///
/// **Lifecycle:**
/// - The session uses a `.background` config so downloads survive app
///   suspension and continue on cellular if the user requested it.
/// - Delegate callbacks fire on URLSession's private queue. The bridge
///   class yields events into an `AsyncStream`; the actor's long-running
///   consumer drains them and updates `DownloadStore`.
/// - On app relaunch (after iOS has woken us to deliver completion
///   events), `recoverExistingTasks()` re-binds tasks left in the
///   session to jobs in the store via `taskDescription = jobID`. The
///   `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
///   bridge in the app target completes the OS-side handler.
///
/// **What this layer does NOT do:**
/// - Doesn't decide *what* to download — `enqueue(item:source:quality:)`
///   takes a `MediaSource` and asks it (via `downloadURL(for:quality:)`)
///   for the right URL. Plex / Jellyfin override that.
/// - Doesn't render UI — views observe `DownloadStore.snapshotStream()`.
public actor DownloadManager {
    private static let log = Logger(subsystem: "cz.zmrhal.aether", category: "downloads.manager")

    /// Background-session identifier. Apple requires this to be unique
    /// per app; it's how iOS finds the same session across relaunches.
    public static let sessionIdentifier = "cz.zmrhal.aether.downloads"

    private let session: URLSession
    private let bridge: URLSessionEventBridge
    private let store: DownloadStore
    private let downloadsDirectory: URL

    /// Active tasks keyed by job id. `URLSessionTask.taskDescription`
    /// carries the same uuid string, so delegate events can map back.
    private var tasksByJobID: [UUID: URLSessionDownloadTask] = [:]

    /// Resume-data blobs for paused downloads. URLSession gives us this
    /// when we cancel a task with `cancel(byProducingResumeData:)`; we
    /// keep it in memory (it's a few hundred KB at most) until the user
    /// resumes — at which point we hand it back to a fresh download
    /// task and the file picks up where it stopped.
    private var resumeDataByJobID: [UUID: Data] = [:]

    /// Job ids whose URLSession task is about to fire
    /// `didCompleteWithError(NSURLErrorCancelled)` because *we* cancelled
    /// it (pause / cancel / remove), not the system or network. The
    /// `.failed` event handler skips ids in this set so a deliberate
    /// pause doesn't immediately get overwritten with status `.failed`.
    /// Cleared once the matching event has been consumed.
    private var expectedCancellations: Set<UUID> = []

    /// Last progress sample per job (bytes + monotonic timestamp), used to
    /// derive transfer speed from successive `didWriteData` callbacks.
    private var lastProgressSample: [UUID: (bytes: Int64, at: ContinuousClock.Instant)] = [:]

    /// Exponentially-smoothed bytes/sec per job, so the displayed speed doesn't
    /// jitter wildly between ticks.
    private var smoothedBytesPerSecond: [UUID: Double] = [:]

    /// Last time we forwarded a progress update to the store (and through to
    /// the UI), keyed by job id. URLSession's `didWriteData` fires ~10× a
    /// second on a fast connection; without this throttle the Storage row's
    /// speed / bytes / ETA flicker so fast they're unreadable. Speed sampling
    /// still happens on every tick (the EMA needs continuous samples to stay
    /// accurate) — only the store write is gated.
    private var lastProgressEmit: [UUID: ContinuousClock.Instant] = [:]

    /// Minimum gap between UI-visible progress updates. 1.5s is slow enough
    /// that "12 MB/s · 4 min left" stays readable, fast enough that the
    /// progress bar still feels alive.
    private static let progressEmitIntervalSeconds: Double = 1.5

    /// How many times we've auto-resumed a job *this process launch* after an
    /// unexpected interruption. Bounded by `maxAutoResumeAttempts` so a hard
    /// failure (dead server, gone file) can't spin in a resume loop. Reset per
    /// launch — reopening the app gives each download a fresh auto-resume.
    private var autoResumeAttempts: [UUID: Int] = [:]
    private static let maxAutoResumeAttempts = 1

    /// Monotonic clock for speed sampling. Wall-clock isn't needed and would be
    /// wrong across system time changes mid-download.
    private let clock = ContinuousClock()

    /// Public init. Async because we recover any in-flight tasks from
    /// the URLSession (relaunch case) and need to wait for the system.
    public init(store: DownloadStore, downloadsDirectory: URL = DownloadManager.defaultDownloadsDirectory()) async {
        self.store = store
        self.downloadsDirectory = downloadsDirectory

        // Make sure the on-disk dir exists and is excluded from iCloud
        // backup. We do this before the URLSession spins up so the
        // delegate has somewhere to move completed temp files to.
        Self.prepareDownloadsDirectory(downloadsDirectory)

        // Build the event stream + bridge. The bridge is a class
        // (URLSessionDownloadDelegate must be NSObject); the actor
        // consumes events from the stream. No retain cycle: the bridge
        // holds the stream's continuation, the actor holds neither.
        // The bridge also needs the downloads directory because it moves
        // the file synchronously inside `didFinishDownloadingTo` — see
        // its type-level doc for the race-condition reason.
        var streamContinuation: AsyncStream<DownloadEvent>.Continuation!
        let stream = AsyncStream<DownloadEvent> { c in streamContinuation = c }
        self.bridge = URLSessionEventBridge(
            continuation: streamContinuation,
            downloadsDirectory: downloadsDirectory
        )

        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        // Run on cellular when the user asks for a download — they
        // already opted in by tapping Download; don't second-guess.
        config.allowsCellularAccess = true
        // Don't let iOS delay the download "until plugged in + on Wi-Fi"
        // unless we explicitly want that (we don't, here).
        config.isDiscretionary = false
        // Wake the app to deliver completion events when the download
        // finishes while we're suspended. The AppDelegate adapter has
        // to forward `handleEventsForBackgroundURLSession` to complete
        // the OS-side handler.
        config.sessionSendsLaunchEvents = true
        self.session = URLSession(configuration: config, delegate: bridge, delegateQueue: nil)

        // Long-running consumer: pumps URLSession events into the actor
        // (and from there, into the store).
        Task { [weak self] in
            for await event in stream {
                guard let self else { continue }
                await self.handle(event)
            }
        }

        // Rebind any tasks already running from a previous launch.
        await recoverExistingTasks()
    }

    // MARK: - Default downloads directory

    /// `~/Library/Application Support/Aether/Downloads/`.
    ///
    /// Application Support is persistent (Caches can be evicted under
    /// storage pressure — bad for a 4 GB film the user is on a plane
    /// with), excluded from iCloud backup by default (no one wants media
    /// in their iCloud Backup), and survives uninstall only via
    /// reinstall+restore (acceptable — re-download is the recovery
    /// path).
    public static func defaultDownloadsDirectory() -> URL {
        let fm = FileManager.default
        let support = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support
            .appendingPathComponent("Aether", isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    private static func prepareDownloadsDirectory(_ url: URL) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            // Belt + braces: Application Support is excluded from iCloud
            // backup by default *for new files*, but the directory itself
            // we created needs explicit tagging to be safe.
            var url = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        } catch {
            log.error("downloads dir setup failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Public API

    /// Queue a download for `item` at the given `quality`. Asks the
    /// source for the right URL, records a `DownloadJob`, and starts
    /// the URLSession task. The status moves to `.downloading(0)`
    /// immediately so UI shows progress without waiting for the first
    /// byte.
    @discardableResult
    public func enqueue(
        item: MediaItem,
        source: any MediaSource,
        quality: PlaybackQuality
    ) async throws -> DownloadJob {
        let job = DownloadJob(
            mediaID: item.id,
            title: item.title,
            posterURL: item.posterURL,
            kind: item.kind,
            seriesTitle: item.seriesTitle,
            seasonNumber: item.seasonNumber,
            episodeNumber: item.episodeNumber,
            quality: quality
        )
        await store.record(job)

        guard let url = try await source.downloadURL(for: item, quality: quality) else {
            await store.updateStatus(job.id, status: .failed(reason: "Source doesn't support downloads."))
            throw DownloadError.sourceDoesNotSupportDownloads
        }

        // Persist the resolved URL on the job so a relaunch can restart the
        // download from scratch when resume data is unavailable, without a
        // live source. Same id → replaces the record, preserving its status.
        let resolvedJob = job.withSourceURL(url)
        await store.record(resolvedJob)

        startFreshTask(jobID: resolvedJob.id, url: url)
        await store.updateStatus(resolvedJob.id, status: .downloading(fractionCompleted: 0))
        Self.log.notice("enqueued job=\(resolvedJob.id, privacy: .public) item=\(item.id.rawValue, privacy: .public) quality=\(quality.rawValue, privacy: .public)")
        return resolvedJob
    }

    /// Pause an active download. Captures URLSession's resume data so
    /// the next `resume` continues from where the file was.
    ///
    /// The `task.cancel(byProducingResumeData:)` call triggers
    /// `didCompleteWithError(NSURLErrorCancelled)` on the delegate —
    /// which, without the `expectedCancellations` guard below, the
    /// `.failed` event handler would then race against this method's
    /// `updateStatus(.paused)` and immediately overwrite the row with
    /// `.failed("Cancelled")`. Marking the id as expected before the
    /// cancel ensures the delegate's `.failed` event is dropped.
    public func pause(_ jobID: UUID) async {
        guard let task = tasksByJobID[jobID] else { return }
        let progress = task.progress.fractionCompleted
        expectedCancellations.insert(jobID)
        let resumeData: Data? = await withCheckedContinuation { cont in
            task.cancel(byProducingResumeData: { data in cont.resume(returning: data) })
        }
        tasksByJobID[jobID] = nil
        clearSpeedTracking(jobID)
        if let resumeData {
            storeResumeData(resumeData, for: jobID)
        }
        await store.updateStatus(jobID, status: .paused(fractionCompleted: progress))
        Self.log.notice("paused job=\(jobID, privacy: .public) progress=\(progress, privacy: .public)")
    }

    /// Resume a paused (or interrupted) download. Prefers URLSession's resume
    /// data — now persisted to disk, so it survives relaunch — and falls back
    /// to a fresh restart from the job's stored URL when the resume data is
    /// gone (RAM evicted, never produced). Only marks `.failed` when neither a
    /// blob nor a URL is available to restart from.
    public func resume(_ jobID: UUID) async {
        guard tasksByJobID[jobID] == nil else { return }  // already running
        await startOrRestart(jobID)
    }

    /// Cancel a download — kills the task, drops the resume data,
    /// **keeps the store record** so the user can re-enqueue from the
    /// same row. Use `remove(_:)` for full deletion + file cleanup.
    public func cancel(_ jobID: UUID) async {
        if let task = tasksByJobID[jobID] {
            // See pause() for the rationale on `expectedCancellations`.
            // Without this, the delegate's `.failed(NSURLErrorCancelled)`
            // would race our `updateStatus(.failed("Cancelled"))` below
            // — same observable result, but cleaner to keep the failure
            // reason we set rather than URLSession's localised string.
            expectedCancellations.insert(jobID)
            task.cancel()
            tasksByJobID[jobID] = nil
        }
        discardResumeData(for: jobID)
        clearSpeedTracking(jobID)
        await store.updateStatus(jobID, status: .failed(reason: "Cancelled"))
        Self.log.notice("cancelled job=\(jobID, privacy: .public)")
    }

    /// Fully remove a download — cancels any task, deletes the on-disk file
    /// **and any partial / resume-data files**, drops the store record. Backs
    /// the Delete action and swipe-to-delete on Detail + Storage, for finished
    /// *and* in-progress downloads.
    public func remove(_ jobID: UUID) async {
        if let task = tasksByJobID[jobID] {
            expectedCancellations.insert(jobID)
            task.cancel()
            tasksByJobID[jobID] = nil
        }
        discardResumeData(for: jobID)
        clearSpeedTracking(jobID)
        autoResumeAttempts[jobID] = nil
        // Remove every file we own for this job: the finished media file
        // (`{jobID}.{ext}`) and the resume-data blob (`{jobID}.resumedata`).
        // Globbing on the id prefix covers both without needing to know the
        // extension a completed file landed with.
        removeFiles(for: jobID)
        await store.delete(jobID)
        Self.log.notice("removed job=\(jobID, privacy: .public)")
    }

    // MARK: - Event handling

    private func handle(_ event: DownloadEvent) async {
        guard let jobID = UUID(uuidString: event.taskDescription) else { return }
        switch event.kind {
        case let .progress(fractionCompleted, receivedBytes, totalBytes):
            // Drop stale ticks. URLSession can deliver a couple of buffered
            // progress events *after* `pause()` / `cancel()` has nil'd our
            // task reference; recording them would overwrite the .paused
            // status we just set with .downloading again — which is exactly
            // the "pause does nothing" bug the user reported.
            guard tasksByJobID[jobID] != nil else { return }

            // Update the EMA on every tick — the smoothed speed depends on a
            // steady sample stream. Throttling only the *emit* keeps the
            // speed accurate while making the UI readable.
            let bps = updateSpeed(jobID: jobID, receivedBytes: receivedBytes)

            // Throttle the store write to once per `progressEmitIntervalSeconds`.
            // First event for a job emits immediately so the row flips from
            // "queued" to "downloading" without a 1.5-second wait.
            let now = clock.now
            if let last = lastProgressEmit[jobID],
               Self.seconds(from: last, to: now) < Self.progressEmitIntervalSeconds {
                return
            }
            lastProgressEmit[jobID] = now

            await store.recordProgress(
                jobID,
                fractionCompleted: fractionCompleted,
                receivedBytes: receivedBytes,
                totalBytes: totalBytes,
                bytesPerSecond: bps
            )

        case let .finished(localURL, sizeBytes):
            // The bridge already moved the file into place
            // (synchronously inside `didFinishDownloadingTo`). The actor
            // just records the destination + size in the store.
            await store.updateStatus(jobID, status: .completed(localURL: localURL, sizeBytes: sizeBytes))
            tasksByJobID[jobID] = nil
            clearSpeedTracking(jobID)
            discardResumeData(for: jobID)
            Self.log.notice("completed job=\(jobID, privacy: .public) size=\(sizeBytes, privacy: .public)B at=\(localURL.lastPathComponent, privacy: .public)")

        case let .failed(error):
            // The task is done either way — drop our handle to it.
            tasksByJobID[jobID] = nil
            clearSpeedTracking(jobID)

            // Was this *our* cancellation (pause / cancel / remove)? If so the
            // matching public method already set the right status; URLSession's
            // delegate event would only overwrite it. Drop the event.
            if expectedCancellations.remove(jobID) != nil { return }

            // Don't clobber a success: URLSession can fire both
            // didFinishDownloading and didCompleteWithError(nil).
            if let mediaID = await jobMediaID(for: jobID),
               case .completed = await store.status(for: mediaID) {
                return
            }

            // Recoverable interruption (app killed mid-download, transient
            // network drop): iOS hands back resume data in the error. Persist
            // it and auto-resume — bounded so a hard failure can't loop. This
            // is what continues a download after the user reopens the app.
            let resumeData = (error as NSError)
                .userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            if let resumeData { storeResumeData(resumeData, for: jobID) }

            let attempts = autoResumeAttempts[jobID, default: 0]
            let sourceURL = await jobSourceURL(jobID)
            let canRestart = resumeData != nil || sourceURL != nil
            if attempts < Self.maxAutoResumeAttempts, canRestart {
                autoResumeAttempts[jobID] = attempts + 1
                Self.log.notice("auto-resuming job=\(jobID, privacy: .public) attempt=\(attempts + 1, privacy: .public)")
                await startOrRestart(jobID)
                return
            }

            await store.updateStatus(jobID, status: .failed(reason: Self.userFacing(error: error)))
            Self.log.error("failed job=\(jobID, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    private func jobSourceURL(_ jobID: UUID) async -> URL? {
        await store.all().first(where: { $0.id == jobID })?.sourceURL
    }

    private func jobMediaID(for jobID: UUID) async -> MediaID? {
        await store.all().first(where: { $0.id == jobID })?.mediaID
    }

    // MARK: - Relaunch recovery

    /// On launch, re-bind tasks the background session kept alive across the
    /// relaunch. A background-config session continues (and persists) its tasks
    /// while the app is gone, so a surviving download just gets re-bound and
    /// keeps reporting progress.
    ///
    /// Downloads that did *not* survive (app force-quit, task terminated while
    /// suspended) are auto-resumed instead by the `.failed` handler: iOS
    /// redelivers their `didCompleteWithError` — with resume data — once we
    /// recreate the session here. Driving auto-resume from that single place
    /// (not also here) avoids racing a late-delivered event into a second,
    /// duplicate download task for the same job.
    private func recoverExistingTasks() async {
        let tasks = await session.allTasks
        for task in tasks {
            guard let descriptionString = task.taskDescription,
                  let jobID = UUID(uuidString: descriptionString),
                  let downloadTask = task as? URLSessionDownloadTask else { continue }
            tasksByJobID[jobID] = downloadTask
        }
        if !tasks.isEmpty {
            Self.log.notice("recovered \(tasks.count, privacy: .public) in-flight tasks on launch")
        }
    }

    // MARK: - Task starting + restart

    /// Start a brand-new download task from a URL (initial enqueue / restart
    /// from scratch when there's no resume data).
    private func startFreshTask(jobID: UUID, url: URL) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let task = session.downloadTask(with: request)
        task.taskDescription = jobID.uuidString
        tasksByJobID[jobID] = task
        task.resume()
    }

    /// Continue a download from persisted resume data if we have it, otherwise
    /// restart fresh from the job's stored URL. Marks `.failed` only when there
    /// is nothing to start from. Sets the status to `.downloading` so the row
    /// flips out of Paused/Failed immediately.
    private func startOrRestart(_ jobID: UUID) async {
        guard tasksByJobID[jobID] == nil else { return }

        if let data = loadResumeData(for: jobID) {
            let task = session.downloadTask(withResumeData: data)
            task.taskDescription = jobID.uuidString
            tasksByJobID[jobID] = task
            discardResumeData(for: jobID)  // consumed; a fresh blob arrives on the next pause
            await store.updateStatus(jobID, status: .downloading(fractionCompleted: task.progress.fractionCompleted))
            task.resume()
            return
        }

        if let url = await jobSourceURL(jobID) {
            startFreshTask(jobID: jobID, url: url)
            await store.updateStatus(jobID, status: .downloading(fractionCompleted: 0))
            return
        }

        await store.updateStatus(
            jobID,
            status: .failed(reason: "Couldn't resume — re-download from the title's page.")
        )
    }

    // MARK: - Resume-data persistence

    /// `{downloadsDirectory}/{jobID}.resumedata` — the blob URLSession hands us
    /// at pause / interruption, persisted so resume survives relaunch.
    private func resumeDataURL(for jobID: UUID) -> URL {
        downloadsDirectory.appendingPathComponent("\(jobID.uuidString).resumedata")
    }

    private func storeResumeData(_ data: Data, for jobID: UUID) {
        resumeDataByJobID[jobID] = data
        try? data.write(to: resumeDataURL(for: jobID), options: .atomic)
    }

    /// In-memory blob if present, else the on-disk one (relaunch case).
    private func loadResumeData(for jobID: UUID) -> Data? {
        if let data = resumeDataByJobID[jobID] { return data }
        return try? Data(contentsOf: resumeDataURL(for: jobID))
    }

    private func discardResumeData(for jobID: UUID) {
        resumeDataByJobID[jobID] = nil
        try? FileManager.default.removeItem(at: resumeDataURL(for: jobID))
    }

    /// Delete every file we own for a job — the finished media file and the
    /// resume-data blob — by matching the `{jobID}.` filename prefix.
    private func removeFiles(for jobID: UUID) {
        let prefix = "\(jobID.uuidString)."
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: downloadsDirectory, includingPropertiesForKeys: nil
        ) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    // MARK: - Speed tracking

    /// Fold a new byte count into the smoothed transfer rate. Returns bytes/sec
    /// (0 until the first interval elapses).
    private func updateSpeed(jobID: UUID, receivedBytes: Int64) -> Double {
        let now = clock.now
        defer { lastProgressSample[jobID] = (receivedBytes, now) }
        guard let last = lastProgressSample[jobID] else { return smoothedBytesPerSecond[jobID] ?? 0 }
        let seconds = Self.seconds(from: last.at, to: now)
        guard seconds > 0 else { return smoothedBytesPerSecond[jobID] ?? 0 }
        let delta = Double(max(0, receivedBytes - last.bytes))
        let instant = delta / seconds
        // Exponential moving average — weight history 0.7 so the readout is
        // steady but still tracks real changes within a couple of ticks.
        let smoothed = smoothedBytesPerSecond[jobID].map { 0.7 * $0 + 0.3 * instant } ?? instant
        smoothedBytesPerSecond[jobID] = smoothed
        return smoothed
    }

    private func clearSpeedTracking(_ jobID: UUID) {
        lastProgressSample[jobID] = nil
        smoothedBytesPerSecond[jobID] = nil
        // Drop the emit timestamp too — without this, a resumed download
        // would skip its first 1.5s of progress because the gate still
        // remembers the old value.
        lastProgressEmit[jobID] = nil
    }

    private static func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let comps = start.duration(to: end).components
        return Double(comps.seconds) + Double(comps.attoseconds) / 1e18
    }

    // MARK: - Error helpers

    private static func userFacing(error: any Error) -> String {
        // HTTP errors are typed; surface the status code first so the user
        // sees "HTTP 401" rather than "The operation couldn't be completed".
        if let httpError = error as? DownloadHTTPError {
            return httpError.shortDescription
        }
        let ns = error as NSError
        // NSURLError codes we care about are surfaced as short text;
        // anything else falls through to `localizedDescription`.
        switch (ns.domain, ns.code) {
        case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet),
             (NSURLErrorDomain, NSURLErrorNetworkConnectionLost):
            return "No internet connection"
        case (NSURLErrorDomain, NSURLErrorCancelled):
            return "Cancelled"
        case (NSURLErrorDomain, NSURLErrorTimedOut):
            return "Timed out"
        default:
            return ns.localizedDescription
        }
    }
}

// MARK: - URLSession bridge

/// Tiny class that conforms to `URLSessionDownloadDelegate` and forwards
/// every relevant callback into an `AsyncStream`. The `DownloadManager`
/// actor drains that stream.
///
/// **The file move happens synchronously in the delegate**, not on the
/// actor side. The temp file URLSession hands us at
/// `didFinishDownloadingTo` lives in the system daemon's container
/// (`/.nofollow/.../com.apple.nsurlsessiond/Downloads/`) and is deleted
/// as soon as the delegate returns. An async actor hop loses the race —
/// we'd see `NSPOSIXError 2` ("No such file or directory") and the
/// download would land as `.failed` after a 100% progress trace. Moving
/// inside the delegate, before the yield, keeps us inside the window
/// URLSession guarantees.
///
/// Lives in this file (not its own) because it's an implementation
/// detail of the manager and has no consumers elsewhere.
private final class URLSessionEventBridge: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let continuation: AsyncStream<DownloadEvent>.Continuation
    /// Where finished downloads land. Captured at init from
    /// `DownloadManager.defaultDownloadsDirectory()`; the bridge re-
    /// creates it on every move attempt as a belt-and-braces against the
    /// system having cleared the Caches container behind our back.
    let downloadsDirectory: URL

    init(continuation: AsyncStream<DownloadEvent>.Continuation,
         downloadsDirectory: URL) {
        self.continuation = continuation
        self.downloadsDirectory = downloadsDirectory
        super.init()
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData _: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        let fraction: Double = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        continuation.yield(DownloadEvent(
            taskDescription: id,
            kind: .progress(
                fractionCompleted: fraction,
                receivedBytes: totalBytesWritten,
                totalBytes: max(0, totalBytesExpectedToWrite)
            )
        ))
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }

        // URLSession fires this callback even when the server returns a
        // non-2xx response — the response body becomes the "downloaded"
        // file. Without an HTTP status check, a Plex remote endpoint
        // returning HTTP 401/500 with a short JSON error body would
        // land as `.completed` with a 89-byte file, indistinguishable
        // from a successful download to the user. Surface non-2xx as a
        // failure with the status code so the UI shows
        // "Failed · HTTP 401" instead of pretending the file is good.
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            continuation.yield(DownloadEvent(
                taskDescription: id,
                kind: .failed(error: DownloadHTTPError(statusCode: response.statusCode))
            ))
            return
        }

        let expected = downloadTask.response?.expectedContentLength ?? -1

        // Synchronous move INSIDE the delegate callback. See the type-
        // level doc comment for why this can't run on the actor.
        //
        // The file extension matters: AVPlayer reads the container
        // format from the path extension before sniffing bytes, so a
        // .mp4 file that's actually an MKV inside fails with
        // AVErrorCodeFileFormatNotRecognized (-11829). For Plex raw
        // Part downloads the server attaches a
        // `Content-Disposition: attachment; filename="…ext"` header —
        // URLResponse parses that into `suggestedFilename`, which gives
        // us the right extension (.mkv, .mov, .mp4, etc.). Transcoded
        // downloads have no Content-Disposition; fall back to the URL
        // path extension or default to .mp4.
        let fileExt = Self.resolveFileExtension(for: downloadTask)
        let destination = downloadsDirectory.appendingPathComponent("\(id).\(fileExt)")
        do {
            // Idempotent: directory may have been cleared by the OS since
            // DownloadManager.init last touched it (Caches eviction, app
            // re-install simulator quirks, etc.). Belt + braces.
            try FileManager.default.createDirectory(
                at: downloadsDirectory, withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            // The temp file is already gone or unmovable — there's nothing
            // we can do here. Forward to the actor as a failure and let
            // the user retry. We deliberately do NOT yield `.finished`
            // because the destination doesn't exist.
            continuation.yield(DownloadEvent(taskDescription: id, kind: .failed(error: error)))
            return
        }

        // Resolve the on-disk size — `expected` is the server-advertised
        // bytes which may not match the actual file (chunked encoding,
        // transcoder cut-off). Read the file's real size for the store.
        let actualSize: Int64 = {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path),
               let size = attrs[.size] as? Int64 {
                return size
            }
            return max(expected, 0)
        }()

        continuation.yield(DownloadEvent(
            taskDescription: id,
            kind: .finished(localURL: destination, sizeBytes: actualSize)
        ))
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: (any Error)?) {
        guard let id = task.taskDescription, let error else { return }
        continuation.yield(DownloadEvent(taskDescription: id, kind: .failed(error: error)))
    }

    /// URLSession signals "all events for the background session have been
    /// delivered to the delegate" — that's the cue to release the OS-side
    /// completion handler so iOS can fully suspend us again. The
    /// `BackgroundDownloadCompletions` singleton is the bridge between the
    /// AppDelegate (which received the closure) and this point.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            BackgroundDownloadCompletions.shared.flushAndClear()
        }
    }

    /// Pick the file extension a finished download should land with.
    /// Order of preference:
    ///   1. `URLResponse.suggestedFilename` — set by URLSession from the
    ///      server's `Content-Disposition: attachment; filename="…"`
    ///      header. Plex includes this on raw Part downloads
    ///      (`?download=1`), Jellyfin includes it on its
    ///      `/Items/{id}/Download` endpoint.
    ///   2. The download URL's own path extension — works for direct
    ///      Part URLs (`/library/parts/.../file.mkv`) when the server
    ///      didn't send Content-Disposition.
    ///   3. `mp4` as the universal fallback (transcoded MP4 downloads
    ///      have no extension in the URL path; the container is mp4).
    static func resolveFileExtension(for task: URLSessionDownloadTask) -> String {
        if let suggested = task.response?.suggestedFilename {
            let ext = (suggested as NSString).pathExtension
            if !ext.isEmpty { return ext.lowercased() }
        }
        if let urlExt = task.originalRequest?.url?.pathExtension, !urlExt.isEmpty {
            return urlExt.lowercased()
        }
        return "mp4"
    }
}

// MARK: - Internal event model

/// Internal bridge → actor handoff. `DownloadEvent` and its kind are
/// `@unchecked Sendable` because they cross an actor boundary — every
/// field is value-typed or Foundation-Sendable in practice (`URL`,
/// `Error`).
private struct DownloadEvent: @unchecked Sendable {
    let taskDescription: String
    let kind: Kind

    enum Kind {
        case progress(fractionCompleted: Double, receivedBytes: Int64, totalBytes: Int64)
        /// Fired AFTER the bridge has synchronously moved the file into
        /// place. `localURL` is the on-disk destination, not a temp path —
        /// the actor handler just needs to record it in the store.
        case finished(localURL: URL, sizeBytes: Int64)
        case failed(error: any Error)
    }
}

// MARK: - Errors

public enum DownloadError: Error, Sendable, Equatable {
    /// The source returned `nil` from `downloadURL(for:quality:)` — no
    /// download capability available for this combination.
    case sourceDoesNotSupportDownloads
}

/// Carries an HTTP status code through the bridge → actor path so the
/// failure message can read "HTTP 401" instead of generic "Cancelled".
struct DownloadHTTPError: Error, Sendable {
    let statusCode: Int

    var shortDescription: String {
        switch statusCode {
        case 401: return "HTTP 401 — server rejected the request (auth)"
        case 403: return "HTTP 403 — server denied the download"
        case 404: return "HTTP 404 — file not found on server"
        case 500...599: return "HTTP \(statusCode) — server error"
        default: return "HTTP \(statusCode)"
        }
    }
}
