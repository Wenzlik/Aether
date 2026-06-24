import Foundation
import Observation

/// Drives the Plex PIN sign-in flow, including Plex Home profile selection.
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
///    │  token arrives → GET /api/v2/home/users
///    │
///    ├── 0–1 profiles ─────────────────────► success(account token)
///    └── 2+ profiles ──► selectingProfile(users)
///                          │  selectProfile(u)
///                          ├── unprotected ─► switch ─► success(profile token)
///                          └── protected ──► PIN entry ─► switch ─► success
///                                              └─ wrong PIN → pinError, stay
/// ```
///
/// `@MainActor` because the view reads state directly. Network work hops to the
/// `PlexAuthClient` / `PlexHomeClient` actors.
@MainActor
@Observable
public final class PlexSignInViewModel {

    public enum State: Equatable, Sendable {
        case idle
        case requesting
        case awaitingUser(pin: PlexAPI.PIN, linkURL: URL)
        case selectingProfile(users: [PlexAPI.HomeUser])
        case success(result: PlexSignInResult)
        case failure(reason: FailureReason)
    }

    public enum FailureReason: Error, Equatable, Sendable {
        case expired
        case timedOut
        case network(message: String)
    }

    public private(set) var state: State = .idle

    /// Set after a wrong PIN so the profile picker can show "try again".
    public private(set) var pinError = false
    /// A profile switch is in flight (disable the grid / show a spinner).
    public private(set) var isSwitching = false

    private let authClient: PlexAuthClient
    private let homeClient: PlexHomeClient
    private let pollInterval: Duration
    private let pollTimeout: Duration
    private var flowTask: Task<Void, Never>?
    private(set) var adminToken: String?

    public init(
        authClient: PlexAuthClient,
        homeClient: PlexHomeClient,
        pollInterval: Duration = .seconds(2),
        pollTimeout: Duration = .seconds(300)
    ) {
        self.authClient = authClient
        self.homeClient = homeClient
        self.pollInterval = pollInterval
        self.pollTimeout = pollTimeout
    }

    /// Kick off (or restart) the flow. Cancels any in-flight flow first.
    public func start() {
        flowTask?.cancel()
        state = .requesting
        pinError = false
        isSwitching = false
        adminToken = nil
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

    // MARK: - Profile selection

    /// Switch to the chosen Home profile (the picker gathers the PIN for
    /// protected profiles and passes it here, or `nil`). On a wrong PIN sets
    /// `pinError` and stays on the picker; on success transitions to `.success`.
    public func chooseProfile(_ user: PlexAPI.HomeUser, pin: String?) {
        guard let adminToken else { return }
        isSwitching = true
        pinError = false
        flowTask = Task { [weak self] in
            guard let self else { return }
            do {
                let token = try await self.homeClient.switchUser(uuid: user.uuid, pin: pin, adminToken: adminToken)
                guard !Task.isCancelled else { return }
                self.isSwitching = false
                self.state = .success(result: PlexSignInResult(token: token, adminToken: adminToken, user: user))
            } catch PlexHomeError.invalidPIN {
                self.isSwitching = false
                self.pinError = true
            } catch is CancellationError {
                return
            } catch {
                self.isSwitching = false
                self.state = .failure(reason: .network(message: error.localizedDescription))
            }
        }
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
            adminToken = token

            // Plex Home: if the account has multiple profiles, let the user pick
            // one (its scoped token replaces the account token). A non-Home
            // account — or a home lookup that fails — just signs in as the
            // account, so the home step never blocks a normal sign-in.
            let users = (try? await homeClient.users(adminToken: token)) ?? []
            guard !Task.isCancelled else { return }
            if users.count > 1 {
                state = .selectingProfile(users: users)
            } else {
                state = .success(result: PlexSignInResult(token: token, adminToken: token, user: nil))
            }
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
