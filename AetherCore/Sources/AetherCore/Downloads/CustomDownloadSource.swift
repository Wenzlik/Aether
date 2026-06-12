import Foundation

/// A `MediaSource` that performs its **own** download transfer instead of
/// handing `DownloadManager` an HTTP(S) URL for a background `URLSession` task
/// (#214 SMB).
///
/// SMB reads file bytes over SMB2/3 (via the app target's SMBClient), which the
/// URLSession pipeline can't do. A source conforming to this runs its transfer
/// as a plain async `Task` inside the manager, reporting fractional progress
/// into the `DownloadStore` exactly like a URLSession download.
///
/// Trade-offs vs the URLSession path (acceptable for LAN SMB):
/// - **No OS background continuation** — the transfer stops if the app is
///   suspended/killed; it resumes from zero when the user reopens and taps
///   Resume (the live source must still exist this process launch).
/// - **No byte-range resume** — pause/resume restarts the file from the start.
/// - A custom download interrupted by app termination can't be auto-resumed
///   without the live source, so it surfaces as failed → re-download.
public protocol CustomDownloadSource: MediaSource {
    /// File extension to give the saved file (e.g. `"mkv"`), derived from the
    /// item's file. `nil` falls back to `"mp4"`.
    func downloadFileExtension(for item: MediaItem) -> String?

    /// Transfer `item` to `destination` (a file URL the manager owns), reporting
    /// fractional progress `0...1`. Must honour task cancellation (throw
    /// `CancellationError`) so pause/cancel stop promptly, and throw on failure.
    func performDownload(
        of item: MediaItem,
        to destination: URL,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws
}
