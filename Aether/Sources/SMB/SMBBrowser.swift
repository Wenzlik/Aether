import Foundation
import OSLog
import VLCKit

/// One entry in an SMB directory listing — a file or a subdirectory. `Sendable`
/// (URL + String + Bool only), so it crosses back to `SMBMediaSource`'s actor
/// without dragging non-Sendable VLCKit types across the boundary (#214).
struct SMBEntry: Sendable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
}

/// Outcome of one browse: VLCKit's final parse status plus whatever entries it
/// produced. The status lets callers tell *why* a listing was empty —
/// unreachable (timeout), rejected (failed), or genuinely empty (done) — which
/// is the difference between an actionable error and a useless "nothing here".
struct SMBBrowseResult: Sendable {
    enum Status: Sendable {
        case done          // reached + finished parsing (may still be empty)
        case timeout       // never answered in time — unreachable / blocked / no Local Network
        case failed        // refused — bad credentials, bad path, or share-enum denied
        case notStarted    // parse couldn't even start (bad URL / no VLC backend)
    }
    let status: Status
    let entries: [SMBEntry]
    /// libsmb2's own last error line for this attempt, if it logged one (e.g.
    /// "STATUS_LOGON_FAILURE", "STATUS_BAD_NETWORK_NAME") — surfaced in the
    /// connect dialog so a refusal explains itself instead of staying generic.
    var diagnostic: String? = nil
    var isEmpty: Bool { entries.isEmpty }
}

/// Headless SMB directory browsing through VLCKit's `libdsm`/`libsmb2` modules.
/// `@MainActor` because VLCKit objects expect a stable thread; only the
/// `[SMBEntry]` result leaves this actor.
///
/// Credentials ride as `VLCMedia` options (`:smb-user=` / `:smb-pwd=` /
/// `:smb-domain=`), never in the URL — so the `smb://` URL stays log-safe and
/// `streamURL` can be stored credential-free.
@MainActor
enum SMBBrowser {
    private static let log = Logger(subsystem: "cz.zmrhal.aether", category: "SMB")

    /// Parse `url` (a directory) and return its immediate children. Empty on
    /// failure / timeout — callers degrade to "nothing here". Thin wrapper over
    /// `browse` for the recursive walk, which doesn't care *why* a dir was empty.
    static func entries(at url: URL, options: [String], timeoutMilliseconds: Int32 = 8000) async -> [SMBEntry] {
        await browse(at: url, options: options, timeoutMilliseconds: timeoutMilliseconds).entries
    }

    /// Install a one-shot libVLC logger that forwards SMB-related messages to
    /// Console. Idempotent. Without this, a refused browse only surfaces as a
    /// generic `failed` — this lets us read libsmb2's actual reason (NT status,
    /// NTLM auth failure, share-enum denial). Filtered to SMB/auth modules so it
    /// doesn't drown Console in playback chatter.
    private static var loggerInstalled = false
    private static func installDiagnosticLoggerIfNeeded() {
        guard !loggerInstalled else { return }
        loggerInstalled = true
        VLCLibrary.shared().loggers = [SMBVLCLogger()]
    }

    /// Parse `url` and return both the entries and VLCKit's final parse status,
    /// so the connect screen can say *why* a listing came back empty.
    static func browse(at url: URL, options: [String], timeoutMilliseconds: Int32 = 8000) async -> SMBBrowseResult {
        installDiagnosticLoggerIfNeeded()
        SMBVLCLogger.resetLastError()
        // Force libsmb2 (SMB2/3) and fold username/domain into the URL — libsmb2
        // reads the identity from the URL, not from VLC's smb-user/smb-domain
        // options (which left it anonymous → refused). Password stays an option.
        let request = smb2VLCRequest(url: url, options: options)
        guard let media = VLCMedia(url: request.url) else {
            log.error("SMB browse: could not build VLCMedia for host \(url.host ?? "?", privacy: .public)")
            return SMBBrowseResult(status: .notStarted, entries: [])
        }
        for option in request.options { media.addOption(option) }

        let delegate = ParseDelegate()
        media.delegate = delegate
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            delegate.onFinish = { continuation.resume() }
            // If the network parse can't even start, don't hang.
            let networkParse = VLCMediaParsingOptions(rawValue: 0x02)   // VLCMediaParseNetwork
            let started = media.parse(options: networkParse, timeout: timeoutMilliseconds)
            if started != 0 { delegate.fire() }
        }

        let status = mapStatus(media.parsedStatus)
        var entries: [SMBEntry] = []
        if let list = media.subitems {
            for index in 0..<max(0, list.count) {
                guard let child = list.media(at: UInt(index)), let childURL = child.url else { continue }
                let isDir = child.mediaType == .directory || childURL.absoluteString.hasSuffix("/")
                let name = childURL.lastPathComponent.removingPercentEncoding ?? childURL.lastPathComponent
                guard !name.isEmpty else { continue }
                entries.append(SMBEntry(url: childURL, name: name, isDirectory: isDir))
            }
        }
        // Host only — never the path/creds — so the log stays safe to share.
        let diagnostic = entries.isEmpty ? SMBVLCLogger.lastError : nil
        log.info("SMB browse host=\(url.host ?? "?", privacy: .public) status=\(String(describing: status), privacy: .public) entries=\(entries.count, privacy: .public) reason=\(diagnostic ?? "-", privacy: .public)")
        return SMBBrowseResult(status: status, entries: entries, diagnostic: diagnostic)
    }

    private static func mapStatus(_ status: VLCMediaParsedStatus) -> SMBBrowseResult.Status {
        switch status {
        case .done: return .done
        case .timeout: return .timeout
        case .failed, .skipped, .cancelled: return .failed
        case .`init`, .pending: return .notStarted
        @unknown default: return .failed
        }
    }

    /// Bridges VLCKit's parse-finished delegate callback to a one-shot
    /// continuation. `@unchecked Sendable` — only ever touched on the main actor.
    private final class ParseDelegate: NSObject, VLCMediaDelegate, @unchecked Sendable {
        var onFinish: (() -> Void)?
        private var fired = false

        func fire() {
            guard !fired else { return }
            fired = true
            let handler = onFinish
            onFinish = nil
            handler?()
        }

        func mediaDidFinishParsing(_ aMedia: VLCMedia) { fire() }
    }
}

/// Forwards libVLC's own log messages to our `os.Logger` so SMB connection
/// failures surface their real cause (NT status / NTLM / share-enum) instead of
/// a bare `failed`. Filtered to SMB / auth / network modules to keep Console
/// readable. `@unchecked Sendable` — libVLC calls in on its own threads; we only
/// read immutable config + emit logs.
final class SMBVLCLogger: NSObject, VLCLogging, @unchecked Sendable {
    private let log = Logger(subsystem: "cz.zmrhal.aether", category: "SMB.vlc")

    // Capture everything; we filter by module/content in `handleMessage`.
    var level: VLCLogLevel = VLCLogLevel(rawValue: 3) ?? .debug   // 3 = debug

    private static let interestingModules = ["smb", "dsm", "keystore", "tls", "access", "stream"]

    /// The most recent SMB-related error/warning line libsmb2 emitted, so the
    /// connect dialog can show *why* a connection was refused. Set on the VLC
    /// log thread, read on the main actor after parse — a lone `String?`, last
    /// write wins; good enough for a human-facing hint. Reset per attempt.
    nonisolated(unsafe) static var lastError: String?
    static func resetLastError() { lastError = nil }

    func handleMessage(_ message: String, logLevel: VLCLogLevel, context: VLCLogContext?) {
        let module = context?.module.lowercased() ?? ""
        let isSMBRelated = Self.interestingModules.contains { module.contains($0) }
            || message.lowercased().contains("smb")
        // Always surface errors/warnings; otherwise only SMB-related chatter.
        guard isSMBRelated || logLevel.rawValue <= 1 else { return }
        let tag = module.isEmpty ? "vlc" : module
        log.info("[\(tag, privacy: .public)] \(message, privacy: .public)")
        // Remember the last SMB-related line as the surfaced reason (any level —
        // libsmb2 often reports the failure at info, not error).
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { Self.lastError = trimmed }
    }
}
