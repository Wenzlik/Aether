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
        var streamContinuation: AsyncStream<DownloadEvent>.Continuation!
        let stream = AsyncStream<DownloadEvent> { c in streamContinuation = c }
        self.bridge = URLSessionEventBridge(continuation: streamContinuation)

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
            quality: quality
        )
        await store.record(job)

        guard let url = try await source.downloadURL(for: item, quality: quality) else {
            await store.updateStatus(job.id, status: .failed(reason: "Source doesn't support downloads."))
            throw DownloadError.sourceDoesNotSupportDownloads
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let task = session.downloadTask(with: request)
        task.taskDescription = job.id.uuidString
        tasksByJobID[job.id] = task
        await store.updateStatus(job.id, status: .downloading(fractionCompleted: 0))
        task.resume()
        Self.log.notice("enqueued job=\(job.id, privacy: .public) item=\(item.id.rawValue, privacy: .public) quality=\(quality.rawValue, privacy: .public)")
        return job
    }

    /// Pause an active download. Captures URLSession's resume data so
    /// the next `resume` continues from where the file was.
    public func pause(_ jobID: UUID) async {
        guard let task = tasksByJobID[jobID] else { return }
        let progress = task.progress.fractionCompleted
        let resumeData: Data? = await withCheckedContinuation { cont in
            task.cancel(byProducingResumeData: { data in cont.resume(returning: data) })
        }
        tasksByJobID[jobID] = nil
        if let resumeData {
            resumeDataByJobID[jobID] = resumeData
        }
        await store.updateStatus(jobID, status: .paused(fractionCompleted: progress))
        Self.log.notice("paused job=\(jobID, privacy: .public) progress=\(progress, privacy: .public)")
    }

    /// Resume a paused download. Needs the resume data captured at
    /// pause time; if it's gone (process died, RAM evicted), falls back
    /// to a fresh start by leaving the status alone — UI shows Failed
    /// and lets the user retry with a new enqueue.
    public func resume(_ jobID: UUID) async {
        guard let resumeData = resumeDataByJobID[jobID] else {
            Self.log.warning("resume job=\(jobID, privacy: .public) but no resume data — needs re-enqueue")
            return
        }
        let task = session.downloadTask(withResumeData: resumeData)
        task.taskDescription = jobID.uuidString
        tasksByJobID[jobID] = task
        resumeDataByJobID[jobID] = nil
        let progress = task.progress.fractionCompleted
        await store.updateStatus(jobID, status: .downloading(fractionCompleted: progress))
        task.resume()
    }

    /// Cancel a download — kills the task, drops the resume data,
    /// **keeps the store record** so the user can re-enqueue from the
    /// same row. Use `remove(_:)` for full deletion + file cleanup.
    public func cancel(_ jobID: UUID) async {
        if let task = tasksByJobID[jobID] {
            task.cancel()
            tasksByJobID[jobID] = nil
        }
        resumeDataByJobID[jobID] = nil
        await store.updateStatus(jobID, status: .failed(reason: "Cancelled"))
        Self.log.notice("cancelled job=\(jobID, privacy: .public)")
    }

    /// Fully remove a download — cancels task, deletes the on-disk
    /// file, drops the store record. The user used the Delete action
    /// on Detail or Storage settings.
    public func remove(_ jobID: UUID) async {
        if let task = tasksByJobID[jobID] {
            task.cancel()
            tasksByJobID[jobID] = nil
        }
        resumeDataByJobID[jobID] = nil
        // If the file landed on disk, remove it.
        if let job = await store.all().first(where: { $0.id == jobID }) {
            let status = await store.status(for: job.mediaID)
            if case let .completed(localURL, _) = status {
                try? FileManager.default.removeItem(at: localURL)
            }
        }
        await store.delete(jobID)
        Self.log.notice("removed job=\(jobID, privacy: .public)")
    }

    // MARK: - Event handling

    private func handle(_ event: DownloadEvent) async {
        guard let jobID = UUID(uuidString: event.taskDescription) else { return }
        switch event.kind {
        case let .progress(fractionCompleted):
            await store.updateStatus(jobID, status: .downloading(fractionCompleted: fractionCompleted))

        case let .finished(tempURL, expectedSize):
            // Move the temp file into our persistent downloads dir
            // *synchronously* on the actor — URLSession deletes the temp
            // file as soon as the delegate returns, and we can't risk
            // racing that.
            let job = await store.all().first(where: { $0.id == jobID })
            let filename = Self.filename(for: job, fallback: jobID.uuidString)
            let destination = downloadsDirectory.appendingPathComponent(filename)
            do {
                // Replace any existing file at the destination (re-download).
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: tempURL, to: destination)
                let size = expectedSize > 0
                    ? expectedSize
                    : (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0).map(Int64.init) ?? 0
                await store.updateStatus(jobID, status: .completed(localURL: destination, sizeBytes: size))
                tasksByJobID[jobID] = nil
                Self.log.notice("completed job=\(jobID, privacy: .public) size=\(size, privacy: .public)B at=\(destination.lastPathComponent, privacy: .public)")
            } catch {
                await store.updateStatus(jobID, status: .failed(reason: Self.userFacing(error: error)))
                tasksByJobID[jobID] = nil
                Self.log.error("move-on-finish failed job=\(jobID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            }

        case let .failed(error):
            // Only mark `.failed` if the task didn't already complete via
            // `.finished` — URLSession can fire both didFinishDownloading
            // and didCompleteWithError(nil) in the success path.
            let current = await store.status(for: await jobMediaID(for: jobID) ?? .init(source: .mock, rawValue: ""))
            if case .completed = current { return }
            await store.updateStatus(jobID, status: .failed(reason: Self.userFacing(error: error)))
            tasksByJobID[jobID] = nil
            Self.log.error("failed job=\(jobID, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    private func jobMediaID(for jobID: UUID) async -> MediaID? {
        await store.all().first(where: { $0.id == jobID })?.mediaID
    }

    // MARK: - Relaunch recovery

    /// On launch, find every task already in the session and re-bind it
    /// to a job. URLSession persists tasks across launches with a
    /// background config — we just need to remember them locally.
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

    // MARK: - Filename + error helpers

    /// Build an on-disk filename that's stable per job (so re-downloads
    /// overwrite, and the file is debuggable when poking around the
    /// container with Files.app). Falls back to `{uuid}.bin` when no
    /// job metadata is available (shouldn't happen in practice).
    private static func filename(for job: DownloadJob?, fallback: String) -> String {
        guard let job else { return "\(fallback).bin" }
        let safeTitle = sanitize(job.title)
        // We don't know the right extension yet — Plex's transcoded
        // download is always .mp4, the Part file matches the source
        // container (.mp4 / .mkv / .mov). For simplicity Phase 2.0
        // settles on `.mp4` (transcoded) when quality is capped,
        // `.bin` otherwise (the player reads the actual container from
        // the file). Will refine when we wire Jellyfin downloads.
        let ext = (job.quality == .original) ? "bin" : "mp4"
        return "\(safeTitle)-\(job.id.uuidString.prefix(8)).\(ext)"
    }

    private static func sanitize(_ raw: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.whitespacesAndNewlines)
        let parts = raw.unicodeScalars.split { forbidden.contains($0) }
        let joined = parts.map { String(String.UnicodeScalarView($0)) }.joined(separator: "_")
        return joined.isEmpty ? "Untitled" : String(joined.prefix(80))
    }

    private static func userFacing(error: any Error) -> String {
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
/// Lives in this file (not its own) because it's an implementation
/// detail of the manager and has no consumers elsewhere.
private final class URLSessionEventBridge: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let continuation: AsyncStream<DownloadEvent>.Continuation

    init(continuation: AsyncStream<DownloadEvent>.Continuation) {
        self.continuation = continuation
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
        continuation.yield(DownloadEvent(taskDescription: id, kind: .progress(fractionCompleted: fraction)))
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        // URLSession will delete `location` after this delegate returns;
        // the manager must move the file inside its event handler. We
        // copy the URL into the event — the manager hops to its actor
        // and moves the file there. URLSession typically gives us a few
        // hundred ms.
        let expected = downloadTask.response?.expectedContentLength ?? -1
        continuation.yield(DownloadEvent(
            taskDescription: id,
            kind: .finished(tempURL: location, expectedSize: expected)
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
        case progress(fractionCompleted: Double)
        case finished(tempURL: URL, expectedSize: Int64)
        case failed(error: any Error)
    }
}

// MARK: - Errors

public enum DownloadError: Error, Sendable, Equatable {
    /// The source returned `nil` from `downloadURL(for:quality:)` — no
    /// download capability available for this combination.
    case sourceDoesNotSupportDownloads
}
