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
        guard let url = Self.normalizedURL(urlString) else {
            state = .failed(message: "Enter a valid server address, e.g. http://192.168.1.10:8096")
            return
        }

        state = .validating
        task?.cancel()
        task = Task {
            do {
                let info = try await authClient.publicInfo(baseURL: url)
                let initiation = try await authClient.initiateQuickConnect(baseURL: url)
                guard !Task.isCancelled else { return }
                state = .awaitingApproval(code: initiation.code)

                let auth = try await authClient.pollForAuthentication(
                    baseURL: url,
                    secret: initiation.secret,
                    interval: pollInterval,
                    timeout: pollTimeout
                )
                guard !Task.isCancelled else { return }
                state = .success(JellyfinServerRecord(
                    baseURLString: url.absoluteString,
                    accessToken: auth.accessToken,
                    userID: auth.user.id,
                    serverName: info.serverName ?? "Jellyfin"
                ))
            } catch is CancellationError {
                // View went away; nothing to do.
            } catch JellyfinAuthError.notEnabled {
                state = .failed(message: "Quick Connect is turned off on this server. Enable it in Jellyfin → Dashboard → Quick Connect, then try again.")
            } catch JellyfinAuthError.invalidServer {
                state = .failed(message: "That doesn't look like a Jellyfin server. Check the address and try again.")
            } catch JellyfinAuthError.timedOut {
                state = .failed(message: "Timed out waiting for approval. Start again to get a fresh code.")
            } catch {
                state = .failed(message: "Couldn't reach the server. Check the address and your network.")
            }
        }
    }

    func reset() {
        task?.cancel()
        state = .enterURL
    }

    /// Accept "host:port" / "host" and prepend a scheme; trim a trailing slash.
    static func normalizedURL(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "http://" + text
        }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.host != nil else { return nil }
        return url
    }
}
