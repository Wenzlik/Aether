import Foundation

/// The state of a download for a given `MediaItem` — what the UI surfaces on
/// poster badges, the Download row on Detail, and the Library "Downloaded"
/// rail.
///
/// `DownloadStore` is the canonical owner; views never persist a status of
/// their own. Status transitions are linear most of the time:
///
/// `.notDownloaded → .queued → .downloading → .completed`
///
/// but `.paused` and `.failed` can interrupt at any point, and `.expired` is
/// what we surface when a `.completed` job's file is gone (storage pressure
/// evicted it from the Caches dir, or the user deleted manually).
public enum DownloadStatus: Sendable, Equatable, Codable {
    /// No record exists for this item — never queued, never started.
    case notDownloaded
    /// Recorded in the store but not yet handed to URLSession (the manager
    /// hasn't started the task, e.g. the queue is capped or we're offline).
    case queued
    /// Active URLSession download task. `fractionCompleted` is `0…1`.
    case downloading(fractionCompleted: Double)
    /// User asked URLSession to pause; resumable via the cached resume data.
    /// `fractionCompleted` snapshots the progress at pause time so the UI
    /// keeps showing "47%" instead of dropping to 0.
    case paused(fractionCompleted: Double)
    /// File present at `localURL`. `sizeBytes` is the final on-disk size.
    case completed(localURL: URL, sizeBytes: Int64)
    /// Terminal — URLSession reported an error, or the manager couldn't move
    /// the temp file into place. `reason` is a short one-line message; the
    /// raw error stays out of the model so views don't leak `NSError`
    /// jargon.
    case failed(reason: String)
    /// A previously-completed download whose file is no longer on disk
    /// (`.notDownloaded` would be wrong — we still remember the user wanted
    /// it, they just need to re-download).
    case expired

    /// `0…1` progress fraction for the states that have one; `nil` for the
    /// rest. Used by progress bars and the disclosure-row "47%" label.
    public var fractionCompleted: Double? {
        switch self {
        case let .downloading(p), let .paused(p): return p
        case .completed: return 1.0
        case .notDownloaded, .queued, .failed, .expired: return nil
        }
    }

    /// `true` once the file is actually playable offline.
    public var isPlayable: Bool {
        if case .completed = self { return true }
        return false
    }

    /// Whether the user can take some action on the row right now (Pause
    /// while downloading, Resume while paused, Retry on failure, Delete on
    /// completion). Drives the disclosure-row's chevron visibility.
    public var isInteractive: Bool {
        switch self {
        case .downloading, .paused, .completed, .failed, .expired: return true
        case .notDownloaded, .queued: return false
        }
    }

    /// The on-disk URL for a `.completed` download, **verified to exist** — so
    /// playback can use the local file instead of falling back to the server
    /// (which fails offline). `nil` for any other state, or when the file can't
    /// be found at either the stored or the re-based location.
    ///
    /// We persist an **absolute** `file://` path at download time, but the iOS
    /// data-container UUID can change under us (restore-from-backup, some
    /// migrations), invalidating that path even though the bytes are still on
    /// disk at `{downloadsDirectory}/{jobID}.{ext}`. So if the stored path no
    /// longer resolves, we re-base its filename onto the *current* downloads
    /// directory and check there before giving up. Without this, a downloaded
    /// title would silently fall through to a Plex/Jellyfin stream and fail
    /// when offline.
    ///
    /// `downloadsDirectory` defaults to the production location; tests that use
    /// a custom directory keep working because the stored absolute path still
    /// resolves there (the re-base is a fallback only).
    public func existingLocalURL(
        downloadsDirectory: URL = DownloadManager.defaultDownloadsDirectory()
    ) -> URL? {
        guard case let .completed(localURL, _) = self else { return nil }
        let fm = FileManager.default
        if fm.fileExists(atPath: localURL.path) { return localURL }
        let rebased = downloadsDirectory.appendingPathComponent(localURL.lastPathComponent)
        return fm.fileExists(atPath: rebased.path) ? rebased : nil
    }
}
