import Foundation

/// Which player should handle a given stream. AVFoundation can't demux some
/// common containers (Matroska/.mkv, AVI, …) — those fall back to VLCKit. Pure
/// + deterministic so the choice is unit-tested and made the same everywhere.
///
/// Server sources (Plex/Jellyfin) hand us HLS (`.m3u8`) or remuxed MP4, which
/// are `.system`; the VLC path only kicks in for local/SMB files in an
/// unsupported container.
public enum PlaybackEngine: Sendable, Equatable {
    /// `AVPlayer` / `AVPlayerViewController` — native controls, PiP, AirPlay.
    case system
    /// VLCKit — handles containers/codecs AVFoundation can't.
    case vlc

    /// Lowercased file extensions AVFoundation opens directly (incl. HLS).
    /// Anything else (mkv, avi, ts, webm, flv, wmv, ogm, m2ts, …) → VLCKit.
    static let systemPlayableExtensions: Set<String> = [
        "mp4", "m4v", "mov", "m4a", "3gp", "3g2", "mp3", "aac", "m3u8"
    ]

    /// Engine for a stream URL, decided by scheme then container extension.
    /// `smb://` always goes to VLCKit — AVPlayer can't open it at all, even for
    /// an `.mp4` (#214). An empty extension (a transcode/HLS URL without one)
    /// defaults to `.system`.
    public static func engine(for url: URL) -> PlaybackEngine {
        if let scheme = url.scheme?.lowercased(), scheme == "smb" { return .vlc }
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty { return .system }
        return systemPlayableExtensions.contains(ext) ? .system : .vlc
    }

    /// Engine for an item, from its `streamURL`. No URL ⇒ `.system`.
    public static func engine(for item: MediaItem) -> PlaybackEngine {
        guard let url = item.streamURL else { return .system }
        return engine(for: url)
    }

    /// Engine for a raw container name (e.g. Plex's `Media.container` —
    /// `"mkv"`, `"mp4"`, …), decided **before** any playback URL exists. Used at
    /// download time to tell whether the *original* file would need VLCKit: on
    /// visionOS the Cinema path docks the system `AVPlayer` (it can't play those
    /// containers locally), so the download UI offers transcode-only for them.
    /// `nil` / empty ⇒ `.system` (don't restrict on an unknown container).
    public static func engine(forContainer container: String?) -> PlaybackEngine {
        guard let container, !container.isEmpty else { return .system }
        return systemPlayableExtensions.contains(container.lowercased()) ? .system : .vlc
    }
}
