import Foundation
import os

/// The single source of truth for download state across the app.
///
/// Backed by a Codable JSON file in **Application Support** (persistent
/// across launches but excluded from the iCloud backup so the user doesn't
/// upload gigabytes of media). The actor wraps an in-memory dict and writes
/// atomically on every mutation — `DownloadManager` is the only writer, UI
/// is read-only via `snapshot()`.
///
/// We don't use SwiftData because the dataset is tiny (a few hundred
/// records at most, growing by ~1 row per download), schema migrations are
/// noise we don't need, and tests prefer plain Codable. If the dataset ever
/// outgrows this it's a one-file replacement.
public actor DownloadStore {
    private static let log = Logger(subsystem: "cz.zmrhal.aether", category: "downloads.store")

    /// Persisted state — jobs + their current statuses. Encoded as one
    /// blob; partial writes don't matter at this size and atomic-replace
    /// keeps the file readable.
    private struct Persisted: Codable {
        var jobs: [UUID: DownloadJob]
        var statuses: [UUID: DownloadStatus]

        static let empty = Persisted(jobs: [:], statuses: [:])
    }

    private var state: Persisted
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    /// Stream of snapshots so UI observers can re-render without polling.
    private var observers: [UUID: AsyncStream<DownloadSnapshot>.Continuation] = [:]

    /// Async init so we can read disk during setup. Failing to read leaves
    /// us with an empty store — we never crash the app for a corrupt /
    /// missing file; the worst case is one redownload.
    public init(fileURL: URL = DownloadStore.defaultFileURL()) async {
        self.fileURL = fileURL
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
        self.state = await Self.load(from: fileURL, decoder: self.decoder)
    }

    // MARK: - Default location

    /// `~/Library/Application Support/Aether/downloads.json`.
    /// Application Support persists across launches (unlike Caches which iOS
    /// can evict), is excluded from backup by default, and is the
    /// platform-recommended home for app-managed state files.
    public static func defaultFileURL() -> URL {
        let fm = FileManager.default
        let support = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let aetherDir = support.appendingPathComponent("Aether", isDirectory: true)
        // Create the directory eagerly; ignore the "already exists" case.
        try? fm.createDirectory(at: aetherDir, withIntermediateDirectories: true)
        return aetherDir.appendingPathComponent("downloads.json")
    }

    // MARK: - Reads

    /// All jobs, newest first. Excludes the `.notDownloaded` items implicit
    /// in everything that *doesn't* have a job here.
    public func all() -> [DownloadJob] {
        state.jobs.values.sorted { $0.createdAt > $1.createdAt }
    }

    /// The job (if any) for an item by its source-scoped id. Cheap O(n) on
    /// the values; jobs count stays small.
    public func job(for mediaID: MediaID) -> DownloadJob? {
        state.jobs.values.first { $0.mediaID == mediaID }
    }

    /// The status for the job tied to this media id — `.notDownloaded`
    /// when nothing has ever been queued. Hides the job→status indirection
    /// from UI callers.
    public func status(for mediaID: MediaID) -> DownloadStatus {
        guard let job = job(for: mediaID) else { return .notDownloaded }
        return state.statuses[job.id] ?? .notDownloaded
    }

    /// O(1) lookup snapshot — useful when a view needs to render many
    /// items (a poster rail) without doing one actor hop per item.
    public func snapshot() -> DownloadSnapshot {
        DownloadSnapshot(
            jobsByMediaID: Dictionary(
                uniqueKeysWithValues: state.jobs.values.map { ($0.mediaID, $0) }
            ),
            statusByJobID: state.statuses
        )
    }

    /// Live stream of `DownloadSnapshot`s, yielding the current value
    /// immediately and a fresh one every time the store mutates. UI
    /// observers should hold the stream's task and cancel on disappear.
    public func snapshotStream() -> AsyncStream<DownloadSnapshot> {
        AsyncStream { continuation in
            let token = UUID()
            observers[token] = continuation
            continuation.yield(snapshot())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(token) }
            }
        }
    }

    private func removeObserver(_ token: UUID) {
        observers.removeValue(forKey: token)
    }

    // MARK: - Mutations

    /// Insert or replace a job. Existing status is preserved (the caller is
    /// re-recording the same job, e.g. on Retry); a new job lands at
    /// `.queued` so UI immediately sees the row appear.
    public func record(_ job: DownloadJob) {
        let isNew = state.jobs[job.id] == nil
        state.jobs[job.id] = job
        if isNew {
            state.statuses[job.id] = .queued
        }
        persistAndPublish()
    }

    /// Update a job's status. No-op when the job doesn't exist — the
    /// URLSession delegate fires after the actor has already removed the
    /// job (e.g. user cancelled while the final write was in flight).
    public func updateStatus(_ jobID: UUID, status: DownloadStatus) {
        guard state.jobs[jobID] != nil else { return }
        state.statuses[jobID] = status
        persistAndPublish()
    }

    /// Remove a job entirely — record + status. The caller is responsible
    /// for deleting the on-disk file; the store doesn't reach into the
    /// filesystem (avoids tangling concerns).
    public func delete(_ jobID: UUID) {
        state.jobs.removeValue(forKey: jobID)
        state.statuses.removeValue(forKey: jobID)
        persistAndPublish()
    }

    // MARK: - Aggregates

    /// Total bytes used by `.completed` downloads, for the Settings →
    /// Storage section. `.downloading` doesn't count yet — partials are
    /// URLSession's temp file, not committed.
    public func totalCompletedSizeBytes() -> Int64 {
        state.statuses.values.reduce(0) { acc, status in
            if case let .completed(_, size) = status { return acc + size }
            return acc
        }
    }

    // MARK: - Persistence

    private func persistAndPublish() {
        let copy = state
        let url = fileURL
        // Encode synchronously inside the actor so two rapid mutations
        // can't reorder on disk; the actual file write is cheap (~few KB).
        do {
            let data = try encoder.encode(copy)
            try data.write(to: url, options: .atomic)
        } catch {
            Self.log.error("downloads.json write failed: \(String(describing: error), privacy: .public)")
        }
        let snap = snapshot()
        for continuation in observers.values {
            continuation.yield(snap)
        }
    }

    private static func load(from fileURL: URL, decoder: JSONDecoder) async -> Persisted {
        guard let data = try? Data(contentsOf: fileURL) else { return .empty }
        do {
            return try decoder.decode(Persisted.self, from: data)
        } catch {
            log.warning("downloads.json corrupt, starting empty: \(String(describing: error), privacy: .public)")
            return .empty
        }
    }
}

// MARK: - DownloadSnapshot

/// An immutable, render-ready view of the store at one point in time.
///
/// UI never actor-hops per item — it grabs a snapshot once per refresh and
/// queries it synchronously while it lays out cards. The snapshot is
/// `Sendable` so it crosses the @MainActor boundary cleanly.
public struct DownloadSnapshot: Sendable, Equatable {
    public let jobsByMediaID: [MediaID: DownloadJob]
    public let statusByJobID: [UUID: DownloadStatus]

    /// The status for a media id — `.notDownloaded` when no job exists.
    public func status(for mediaID: MediaID) -> DownloadStatus {
        guard let job = jobsByMediaID[mediaID] else { return .notDownloaded }
        return statusByJobID[job.id] ?? .notDownloaded
    }

    /// The job behind a media id, if any.
    public func job(for mediaID: MediaID) -> DownloadJob? {
        jobsByMediaID[mediaID]
    }

    /// All jobs whose status is `.completed`, sorted newest first — the
    /// data behind the Library "Downloaded" rail.
    public var completed: [DownloadJob] {
        jobsByMediaID.values
            .filter {
                if case .completed = statusByJobID[$0.id] { return true }
                return false
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public static let empty = DownloadSnapshot(jobsByMediaID: [:], statusByJobID: [:])
}
