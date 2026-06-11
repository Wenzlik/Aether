import Foundation
import VLCKit

/// One entry in an SMB directory listing — a file or a subdirectory. `Sendable`
/// (URL + String + Bool only), so it crosses back to `SMBMediaSource`'s actor
/// without dragging non-Sendable VLCKit types across the boundary (#214).
struct SMBEntry: Sendable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
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
    /// Parse `url` (a directory) and return its immediate children. Empty on
    /// failure / timeout — callers degrade to "nothing here".
    static func entries(at url: URL, options: [String], timeoutMilliseconds: Int32 = 8000) async -> [SMBEntry] {
        guard let media = VLCMedia(url: url) else { return [] }
        for option in options { media.addOption(option) }

        let delegate = ParseDelegate()
        media.delegate = delegate
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            delegate.onFinish = { continuation.resume() }
            // If the network parse can't even start, don't hang.
            let networkParse = VLCMediaParsingOptions(rawValue: 0x02)   // VLCMediaParseNetwork
            let started = media.parse(options: networkParse, timeout: timeoutMilliseconds)
            if started != 0 { delegate.fire() }
        }

        guard let list = media.subitems else { return [] }
        var entries: [SMBEntry] = []
        for index in 0..<max(0, list.count) {
            guard let child = list.media(at: UInt(index)), let childURL = child.url else { continue }
            let isDir = child.mediaType == .directory || childURL.absoluteString.hasSuffix("/")
            let name = childURL.lastPathComponent.removingPercentEncoding ?? childURL.lastPathComponent
            guard !name.isEmpty else { continue }
            entries.append(SMBEntry(url: childURL, name: name, isDirectory: isDir))
        }
        return entries
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
