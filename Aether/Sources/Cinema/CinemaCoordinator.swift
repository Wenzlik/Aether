#if os(visionOS)
import SwiftUI
import AetherCore

/// The single source of truth for "are we in the cinema, and what's playing."
///
/// Owns the immersive-space lifecycle *intent* and the live cinema
/// configuration (screen preset, environment). It deliberately does **not**
/// hold the `openImmersiveSpace` / `dismissImmersiveSpace` actions — those are
/// SwiftUI environment values only reachable from a `View`, so `RootTabView`
/// watches `openRequestID` / `closeRequestID` and performs the actual
/// transition, then calls back `didEnter()` / `didLeave()`. This keeps the
/// coordinator testable and free of view-environment plumbing.
///
/// It holds a reference to the shared `PlaybackSession` only so the immersive
/// view can vend its `AVPlayer` to the screen entity — Cinema never reaches
/// into the playback engine's internals (see
/// `docs/next-steps/visionos-cinema.md` → §0).
@MainActor
@Observable
final class CinemaCoordinator {
    /// Stable identifier for the single `ImmersiveSpace`. One space, one
    /// environment at a time; future environments switch the scene contents,
    /// not the space.
    static let spaceID = "AetherCinema"
    /// Identifier of the main app `WindowGroup`. The cinema dismisses this
    /// window on entry (so only the immersive screen remains, not a window
    /// floating in the void) and reopens it on exit.
    static let mainWindowID = "AetherMain"

    /// Where we are in the enter → present → exit cycle. `RootTabView` reads
    /// this; nothing outside the coordinator mutates it.
    enum Phase: Equatable {
        case windowed
        case entering
        case presenting
        case exiting
    }

    private(set) var phase: Phase = .windowed

    var isPresenting: Bool { phase == .presenting }

    // MARK: - Active playback context

    /// What the cinema is (or is about to be) playing. Set by `watch(...)`,
    /// read by `CinemaImmersiveView` once the space opens.
    private(set) var item: MediaItem?
    /// The source the item came from — resolves a fresh playback URL, exactly
    /// like the windowed player. `nil` for sources without a resolver.
    private(set) var source: (any MediaSource)?
    /// Where playback begins: `nil` resumes from the persisted point, `0`
    /// restarts. Mirrors the windowed player's `startAt`.
    private(set) var startAt: Double?

    // MARK: - Live configuration

    /// Current screen size. Persisted defaults arrive with the Personal Cinema
    /// phase; for now it starts at the global default and the size switcher
    /// mutates it live.
    var screenPreset: CinemaScreenPreset = .default
    /// Current environment. Only `.darkTheater` is buildable in V1.
    var environment: CinemaEnvironment = .default

    // MARK: - Transition signalling

    /// Bumped when the coordinator wants the space opened; `RootTabView`
    /// observes it. A token (not a `Bool`) so repeated requests are distinct.
    /// (Dismissal isn't signalled here — `CinemaImmersiveView` owns it, because
    /// the main window is gone while the cinema is open, so `RootTabView` can't
    /// drive the exit.)
    private(set) var openRequestID: UUID?

    // MARK: - Intent

    /// Enter the cinema with a title. No-op if we're not currently windowed —
    /// a second tap while a transition is in flight is ignored.
    func watch(_ item: MediaItem, source: (any MediaSource)?, startAt: Double?) {
        guard phase == .windowed else { return }
        self.item = item
        self.source = source
        self.startAt = startAt
        phase = .entering
        openRequestID = UUID()
    }

    // MARK: - Lifecycle callbacks

    /// The space finished opening (called by `RootTabView`).
    func didEnter() {
        guard phase == .entering else { return }
        phase = .presenting
    }

    /// The space finished dismissing (or failed to open). Clears the playback
    /// context so the next `watch(...)` starts clean.
    func didLeave() {
        phase = .windowed
        item = nil
        source = nil
        startAt = nil
    }
}
#endif
