import Foundation

/// A point-in-time, **token-free** snapshot of the app's state for the
/// user-facing Diagnostics screen and the "Send Diagnostics" email. Gathered by
/// `SettingsViewModel.gatherDiagnostics()`. Never contains tokens, passwords, or
/// credentials — only counts, sizes, and environment facts.
struct DiagnosticsSnapshot: Sendable {
    struct SourceLine: Identifiable, Sendable {
        /// A non-sensitive key — source *kind* + index (e.g. "jellyfin-0"). Must
        /// NEVER embed a server URL, host, or token (those live in
        /// `MediaSourceID.stableKey`, which must not be put here).
        let id: String
        let name: String
        let status: String
    }

    // App
    var appVersion: String
    var buildNumber: String
    var commit: String?
    var platform: String
    var deviceModel: String
    var osVersion: String
    var theme: String
    // Sources
    var sources: [SourceLine]
    // Library
    var movieCount: Int
    var showCount: Int
    // Downloads
    var downloadCount: Int
    var downloadBytes: Int64
    // Cache
    var imageCacheBytes: Int64
    // Playback
    var audioPreference: String
    var subtitlePreference: String
    // Meta
    var generatedAt: Date

    /// Build line preferring the stamped commit over the local-only build number.
    var buildIdentifier: String { commit ?? buildNumber }

    private static func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        return formatter.string(fromByteCount: count)
    }

    var imageCacheText: String { Self.bytes(imageCacheBytes) }
    var downloadBytesText: String { Self.bytes(downloadBytes) }

    /// A readable plain-text report — body + attachment for "Send Diagnostics".
    func report() -> String {
        var lines: [String] = []
        lines.append("Aether Diagnostics")
        lines.append("==================")
        lines.append("")
        lines.append("APP")
        lines.append("Version: \(appVersion)")
        lines.append("Build: \(buildNumber)")
        if let commit { lines.append("Commit: \(commit)") }
        lines.append("Platform: \(platform)")
        lines.append("Device: \(deviceModel)")
        lines.append("OS: \(osVersion)")
        lines.append("Theme: \(theme)")
        lines.append("")
        lines.append("SOURCES")
        if sources.isEmpty {
            lines.append("None connected")
        } else {
            for source in sources { lines.append("\(source.name): \(source.status)") }
        }
        lines.append("")
        lines.append("LIBRARY")
        lines.append("Movies: \(movieCount)")
        lines.append("TV Shows: \(showCount)")
        lines.append("")
        lines.append("DOWNLOADS")
        lines.append("Count: \(downloadCount)")
        lines.append("Storage: \(downloadBytesText)")
        lines.append("")
        lines.append("CACHE")
        lines.append("Images: \(imageCacheText)")
        lines.append("")
        lines.append("PLAYBACK")
        lines.append("Audio: \(audioPreference)")
        lines.append("Subtitles: \(subtitlePreference)")
        lines.append("")
        lines.append("Generated: \(generatedAt.ISO8601Format())")
        lines.append("(No tokens, passwords, or credentials are included.)")
        return lines.joined(separator: "\n")
    }
}
