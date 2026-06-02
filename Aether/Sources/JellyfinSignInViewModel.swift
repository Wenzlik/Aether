import Foundation
import AetherCore

/// Drives the Jellyfin sign-in flow: validate the typed server URL, start Quick
/// Connect, show the code, and poll until the user approves it in their
/// Jellyfin dashboard. Mirrors `PlexSignInViewModel` in spirit.
@MainActor
@Observable
final class JellyfinSignInViewModel {
    enum State: Equatable {
        case enterURL
        case validating
        /// Show this code; the user approves it in Jellyfin → Quick Connect.
        case awaitingApproval(code: String)
        case success(JellyfinServerRecord)
        case failed(message: String)
    }

    private(set) var state: State = .enterURL

    private let authClient: JellyfinAuthClient?
    private let pollInterval: Duration
    private let pollTimeout: Duration
    private var task: Task<Void, Never>?

    init(
        authClient: JellyfinAuthClient?,
        pollInterval: Duration = .seconds(2),
        pollTimeout: Duration = .seconds(300)
    ) {
        self.authClient = authClient
        self.pollInterval = pollInterval
        self.pollTimeout = pollTimeout
    }

    func connect(to urlString: String) {
        guard let authClient else {
            state = .failed(message: "Jellyfin isn't ready yet. Try again in a moment.")
            return
        }
        let candidates = Self.candidateURLs(urlString)
        guard !candidates.isEmpty else {
            state = .failed(message: "Enter a server address, like 192.168.1.10:8096 or jellyfin.example.com")
            return
        }

        state = .validating
        task?.cancel()
        task = Task {
            // The user may type a hostname (often HTTPS behind a reverse proxy)
            // or an IP:port (usually plain HTTP). Probe each candidate scheme and
            // use the first that answers as a real Jellyfin server, instead of
            // hard-coding http:// and reporting a reachable server as "invalid".
            var resolved: (url: URL, name: String?)?
            for url in candidates {
                if Task.isCancelled { return }
                if let info = try? await authClient.publicInfo(baseURL: url) {
                    resolved = (url, info.serverName)
                    break
                }
            }
            guard let resolved else {
                state = .failed(message: "Couldn't reach a Jellyfin server at that address. Check the address and that the server is on.")
                return
            }

            do {
                let initiation = try await authClient.initiateQuickConnect(baseURL: resolved.url)
                guard !Task.isCancelled else { return }
                state = .awaitingApproval(code: initiation.code)

                let auth = try await authClient.pollForAuthentication(
                    baseURL: resolved.url,
                    secret: initiation.secret,
                    interval: pollInterval,
                    timeout: pollTimeout
                )
                guard !Task.isCancelled else { return }
                state = .success(JellyfinServerRecord(
                    baseURLString: resolved.url.absoluteString,
                    accessToken: auth.accessToken,
                    userID: auth.user.id,
                    serverName: resolved.name ?? "Jellyfin"
                ))
            } catch is CancellationError {
                // View went away; nothing to do.
            } catch JellyfinAuthError.notEnabled {
                state = .failed(message: "Quick Connect is turned off on this server. Enable it in Jellyfin → Dashboard → Quick Connect, then try again.")
            } catch JellyfinAuthError.timedOut {
                state = .failed(message: "Timed out waiting for approval. Start again to get a fresh code.")
            } catch {
                state = .failed(message: "Couldn't complete sign-in. Check the server and try again.")
            }
        }
    }

    func reset() {
        task?.cancel()
        state = .enterURL
    }

    /// Turn the typed address into ordered base-URL candidates to probe.
    ///
    /// - An explicit `http(s)://` scheme is trusted as-is.
    /// - Otherwise we try both schemes. A bare hostname (e.g.
    ///   `jellyfin.example.com`) is usually HTTPS behind a reverse proxy, so
    ///   HTTPS is tried first; an IP or an explicit `:port` (the typical LAN
    ///   Jellyfin on `:8096`) is usually plain HTTP, so HTTP is tried first.
    static func candidateURLs(_ raw: String) -> [URL] {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty else { return [] }

        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let url = URL(string: text), url.host != nil else { return [] }
            return [url]
        }

        let preferHTTP = hasExplicitPort(text) || isIPLiteral(text)
        let ordered = preferHTTP
            ? ["http://\(text)", "https://\(text)"]
            : ["https://\(text)", "http://\(text)"]
        return ordered.compactMap { URL(string: $0) }.filter { $0.host != nil }
    }

    private static func hasExplicitPort(_ host: String) -> Bool {
        guard let colon = host.lastIndex(of: ":") else { return false }
        let after = host[host.index(after: colon)...]
        return !after.isEmpty && after.allSatisfy(\.isNumber)
    }

    private static func isIPLiteral(_ host: String) -> Bool {
        let head = host.split(separator: ":").first.map(String.init) ?? host
        let parts = head.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { part in
            Int(part).map { (0...255).contains($0) } ?? false
        }
    }
}
