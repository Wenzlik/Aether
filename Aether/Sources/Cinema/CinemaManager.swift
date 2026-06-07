#if os(visionOS)
import SwiftUI
import os
import AetherCore

/// The **single source of truth** for Cinema Mode state on visionOS.
///
/// It holds *only* state — which item is playing in the cinema, and whether we
/// are in the cinema at all. It deliberately owns **none** of: video rendering,
/// playback controls, or screen sizing. Those are the system's job
/// (`AVPlayerViewController` + system docking) — re-implementing them is exactly
/// what made the first prototype fragile (see
/// `docs/next-steps/visionos-cinema.md` → Part 1).
///
/// Flow (driven by `RootTabView`, which has the window-scoped environment
/// actions): `present(...)` sets the context and bumps `openRequestID` →
/// `RootTabView` opens the immersive space and shows the native player, which
/// the system docks into the Dark Theater. `end()` bumps `closeRequestID` →
/// `RootTabView` dismisses the space.
@MainActor
@Observable
final class CinemaManager {
    /// The single Dark Theater immersive-space id. One authored environment for
    /// every preset — the chosen `preset` sizes the docked screen *in code*
    /// (scaling the authored `DockingRegion`), so there's no per-preset space.
    /// `RootTabView` opens this id; `AetherApp` registers the matching space.
    static let spaceID = "AetherCinema"
    var currentSpaceID: String { Self.spaceID }

    /// Diagnostics — `log stream --predicate 'subsystem == "cz.zmrhal.aether"'`
    /// filtered to category `cinema` shows the enter/exit path firing.
    private static let log = Logger(subsystem: "cz.zmrhal.aether", category: "cinema")

    enum Phase: Equatable {
        case idle
        case active
    }

    private(set) var phase: Phase = .idle
    var isActive: Bool { phase == .active }

    // MARK: - Playback context

    /// What the cinema is showing. Set by `present(...)`, read when the player
    /// is shown.
    private(set) var item: MediaItem?
    /// The source the item came from — resolves a fresh playback URL, exactly
    /// like the windowed player.
    private(set) var source: (any MediaSource)?
    /// Where playback begins: `nil` resumes from the persisted point, `0`
    /// restarts. Mirrors the windowed player's `startAt`.
    private(set) var startAt: Double?
    /// The chosen screen-size preset for this session — selects which authored
    /// environment (and thus docked-screen size) the cinema opens. Defaults to
    /// the user's persisted preference, passed in by `present(...)`.
    private(set) var preset: CinemaScreenPreset = .default

    // MARK: - Intent signalling

    /// Bumped to request entering the cinema; `RootTabView` observes it. Tokens
    /// (not `Bool`) so repeated requests stay distinct.
    private(set) var openRequestID: UUID?
    /// Bumped to request leaving the cinema.
    private(set) var closeRequestID: UUID?

    // MARK: - Intent

    /// Enter the cinema with a title. No-op while already active (guards against
    /// a double-tap mid-transition).
    func present(
        _ item: MediaItem,
        source: (any MediaSource)?,
        startAt: Double?,
        preset: CinemaScreenPreset = .default
    ) {
        guard phase == .idle else {
            Self.log.debug("present IGNORED (already active) item=\(item.id.rawValue, privacy: .public)")
            return
        }
        self.item = item
        self.source = source
        self.startAt = startAt
        self.preset = preset
        phase = .active
        openRequestID = UUID()
        Self.log.debug("present item=\(item.id.rawValue, privacy: .public) → request open space")
    }

    /// Leave the cinema. Idempotent — safe to call from a player dismissal that
    /// may or may not have been a cinema session.
    func end() {
        guard phase == .active else {
            Self.log.debug("end (no-op, already idle)")
            return
        }
        phase = .idle
        item = nil
        source = nil
        startAt = nil
        closeRequestID = UUID()
        Self.log.debug("end → request close space")
    }
}
#endif
