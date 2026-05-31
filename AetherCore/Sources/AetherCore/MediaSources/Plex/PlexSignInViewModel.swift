import Foundation
import Observation

/// Drives the Plex PIN sign-in flow for the view layer.
///
/// State machine:
/// ```
///   idle
///    │  start()
///    ▼
///   requesting              POST /api/v2/pins
///    │  on success
///    ▼
///   awaitingUser(pin, url)  poll /api/v2/pins/{id} in background
///    │             │
///    │             ├── token arrives ───► success(token)
///    │             ├── pin expires   ───► failure(.expired)
///    │             ├── timeout       ───► failure(.timedOut)
///    │             └── cancel()      ───► idle
///    ▼
///   failure(reason)
///    └── retry() ─► start()
/// ```
///
/// `@MainActor` because the view reads `state` directly. The polling itself
/// lives on `PlexAuthClient` (an actor); we just `await` it and update state
/// when it returns.
@MainActor
@Observable
public final class PlexSignInViewModel {

    public enum State: Equatable, Sendable {
        case idle
        case requesting
        case awaitingUser(pin: PlexAPI.PIN, linkURL: URL)
        case success(token: String)
        case failure(reason: FailureReason)
    }

    public enum FailureReason: Error, Equatable, Sendable {
        case expired
        case timedOut
        case network(message: String)
    }

    public private(set) var state: State = .idle

    private let authClient: PlexAuthClient
    private let pollInterval: Duration
    private let pollTimeout: Duration
    private var flowTask: Task<Void, Never>?

    public init(
        authClient: PlexAuthClient,
        pollInterval: Duration = .seconds(2),
        pollTimeout: Duration = .seconds(300)
    ) {
        self.authClient = authClient
        self.pollInterval = pollInterval
        self.pollTimeout = pollTimeout
    }

    /// Kick off (or restart) the flow. Cancels any in-flight flow first.
    public func start() {
        flowTask?.cancel()
        state = .requesting
        flowTask = Task { [weak self] in
            await self?.run()
        }
    }

    /// Reset to idle. Cancels any in-flight network work.
    public func cancel() {
        flowTask?.cancel()
        flowTask = nil
        state = .idle
    }

    /// Convenience: cancel + start.
    public func retry() {
        cancel()
        start()
    }

    // MARK: - Flow body

    private func run() async {
        do {
            let pin = try await authClient.requestPIN()
            let url = authClient.linkURL(for: pin)
            guard !Task.isCancelled else { return }
            state = .awaitingUser(pin: pin, linkURL: url)

            let token = try await authClient.pollForToken(
                pinID: pin.id,
                interval: pollInterval,
                timeout: pollTimeout
            )
            guard !Task.isCancelled else { return }
            state = .success(token: token)
        } catch is CancellationError {
            // Explicit cancel — leave state untouched (cancel() already set it).
            return
        } catch PlexAuthError.expired {
            state = .failure(reason: .expired)
        } catch PlexAuthError.timedOut {
            state = .failure(reason: .timedOut)
        } catch {
            guard !Task.isCancelled else { return }
            state = .failure(reason: .network(message: error.localizedDescription))
        }
    }
}
