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
    /// The live screen-size preset. Initialised from the persisted default on
    /// `present(...)`, then mutable so the in-cinema control can resize the
    /// docked screen while watching. `DarkTheaterView` observes it.
    var screenPreset: CinemaScreenPreset = .default
    /// The live seat (row). Initialised from the persisted default on
    /// `present(...)`, then mutable so the in-cinema control can move the
    /// viewer's row while watching. `DarkTheaterView` observes it.
    var seat: CinemaSeat = .default

    // MARK: - Intent signalling

    /// Bumped to request entering the cinema; `RootTabView` observes it. Tokens
    /// (not `Bool`) so repeated requests stay distinct.
    private(set) var openRequestID: UUID?
    /// Bumped to request leaving the cinema.
    private(set) var closeRequestID: UUID?
    /// Bumped when the live size/seat changes and the docked screen must be
    /// re-fitted. visionOS reads the `DockingRegion` only at dock-attach, so the
    /// player wrapper observes this and briefly re-docks (`.embedded` →
    /// `.expanded`) to pick up the new size/position. `DarkTheaterView` bumps it
    /// *after* it has updated the region, so the re-dock reads the new values.
    private(set) var redockToken: UUID?

    // MARK: - Intent

    /// Enter the cinema with a title. No-op while already active (guards against
    /// a double-tap mid-transition).
    func present(
        _ item: MediaItem,
        source: (any MediaSource)?,
        startAt: Double?,
        preset: CinemaScreenPreset = .default,
        seat: CinemaSeat = .default
    ) {
        guard phase == .idle else {
            Self.log.debug("present IGNORED (already active) item=\(item.id.rawValue, privacy: .public)")
            return
        }
        self.item = item
        self.source = source
        self.startAt = startAt
        self.screenPreset = preset
        self.seat = seat
        phase = .active
        openRequestID = UUID()
        Self.log.debug("present item=\(item.id.rawValue, privacy: .public) → request open space")
    }

    /// Change the screen size live (from the in-cinema control) and remember it
    /// as the new default. `DarkTheaterView` observes `screenPreset` and resizes
    /// the docked screen.
    func setScreenPreset(_ preset: CinemaScreenPreset) {
        screenPreset = preset
        CinemaPreferencesStore().screenPreset = preset
        Self.log.debug("cinema: screenPreset → \(preset.rawValue, privacy: .public)")
    }

    /// Change the seat (row) live and remember it. `DarkTheaterView` observes
    /// `seat` and slides the theater.
    func setSeat(_ seat: CinemaSeat) {
        self.seat = seat
        CinemaPreferencesStore().seat = seat
        Self.log.debug("cinema: seat → \(seat.rawValue, privacy: .public)")
    }

    /// Ask the docked player to re-fit to the current size/seat. Called by
    /// `DarkTheaterView` right after it updates the `DockingRegion`, so the
    /// player's re-dock reads the new region. No-op effect until the player
    /// wrapper acts on the token.
    func requestRedock() {
        redockToken = UUID()
        Self.log.debug("cinema: requestRedock")
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
