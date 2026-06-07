import SwiftUI
import AVKit

/// Native `AVPlayerViewController`, wrapped for SwiftUI.
///
/// SwiftUI's `VideoPlayer` was fine as a 0.1 prototype but is deliberately
/// limited. `AVPlayerViewController` is what a premium media app uses — it
/// brings, for free:
/// - device rotation + a proper full-screen presentation,
/// - the system transport bar (scrub, skip, time),
/// - Picture-in-Picture and AirPlay,
/// - the subtitle / audio-track picker.
///
/// **Dismiss surface.** Every platform routes back through app-owned chrome:
/// - iOS / iPadOS: the auto-hiding overlay xmark.
/// - visionOS: a single native AVKit `Back` contextual action. It's the
///   reliable escape hatch when `AVPlayerViewController` owns gaze / pinch
///   routing — a SwiftUI overlay chevron there only duplicated both this
///   action and the system window ornament, so we don't draw one.
/// - tvOS: the Menu button on the Siri Remote (`.onExitCommand`).
/// We don't attach a `Done` `contextualAction` to `AVPlayerViewController`
/// on tvOS — earlier attempts pinned it to the lower-right of the transport
/// where it competed with the system transport controls and felt like
/// chrome clutter. Menu is the platform's canonical dismiss; one path is
/// enough.
///
/// Used on iOS, tvOS, and visionOS (all have UIKit + AVKit).
///
/// **Cinema controls live in the transport bar (visionOS).** Screen size + seat
/// are surfaced as native `contextualActions` next to `Back` — *not* as a
/// floating RealityKit panel. Two reasons, both reported on device: (1) a
/// RealityKit attachment can't composite over the system-docked video, so at the
/// largest screen sizes a floating panel hides *behind* the picture; native
/// chrome renders in the system layer, always in front. (2) Contextual actions
/// appear and disappear *with* the native transport bar, so there's no always-
/// visible handle cluttering the view while watching. See `CinemaControlBinding`.
/// Bridges the Cinema size/seat controls into the native AVKit transport bar as
/// contextual actions. Each is a single cycling button — tap "Screen" to step up
/// a size (wrapping `Wall → Medium`), tap "Seat" to step a row — with the current
/// value shown in the title (e.g. `Screen · Large`). The closures read/mutate
/// `CinemaManager`; built by `DetailView` on visionOS, `nil` for every windowed
/// (non-cinema) playback, which surfaces only `Back`. Closures are `@MainActor`
/// because they touch the main-actor `CinemaManager` and run from the (main-
/// actor) `UIAction` handler.
struct CinemaControlBinding {
    /// Current screen-size label, read fresh whenever the actions are rebuilt so
    /// the button title reflects the live size after a cycle.
    var sizeTitle: @MainActor () -> String
    /// Advance the screen size to the next preset (`wall → medium` wraps).
    var cycleSize: @MainActor () -> Void
    /// Current seat label.
    var seatTitle: @MainActor () -> String
    /// Advance the seat to the next row (`back → front` wraps).
    var cycleSeat: @MainActor () -> Void
}

struct SystemVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    let onDismiss: () -> Void
    /// visionOS Cinema only: surfaces Screen-size + Seat cyclers in the native
    /// transport bar. `nil` for windowed playback (Back-only chrome).
    let cinemaControls: CinemaControlBinding?
    /// visionOS only: when `true`, request the **expanded** experience once the
    /// controller is in the hierarchy, so the player auto-docks into the open
    /// immersive space without the user tapping the expand control. Used by
    /// Cinema Mode; windowed playback leaves it `false`.
    let preferExpanded: Bool
    /// visionOS only: a token bumped when the cinema's size/seat changes. The
    /// system reads the `DockingRegion` only at dock-attach, so an already-docked
    /// screen is re-fitted by briefly transitioning `.expanded` → `.embedded` →
    /// `.expanded` (a quick re-dock). `nil` / unchanged → no re-dock; windowed
    /// playback leaves it `nil`.
    let redockToken: UUID?

    init(
        player: AVPlayer,
        preferExpanded: Bool = false,
        redockToken: UUID? = nil,
        cinemaControls: CinemaControlBinding? = nil,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.player = player
        self.preferExpanded = preferExpanded
        self.redockToken = redockToken
        self.cinemaControls = cinemaControls
        self.onDismiss = onDismiss
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        configureAudioSession()

        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        #if os(iOS)
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.videoGravity = .resizeAspect
        #elseif os(visionOS)
        // visionOS: explicit *false* on `canStartPictureInPictureAutomaticallyFromInline`.
        // The default `true` causes the system to spin up an additional PiP
        // surface when focus/gaze drifts away from the inline player — and
        // since the inline player is still rendered behind it, the user
        // sees *two transport bars* simultaneously, which they reported. PiP
        // is still available via the explicit button in AVKit's chrome;
        // we just stop the system from auto-starting it.
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        controller.videoGravity = .resizeAspect
        // Transport-bar actions: Back, plus (in Cinema) the live Screen-size +
        // Seat cyclers. Built on the Coordinator so a cycle can re-set them with
        // the updated title. See `Coordinator.applyContextualActions`.
        context.coordinator.controller = controller
        context.coordinator.cinemaControls = cinemaControls
        context.coordinator.applyContextualActions()
        // Cinema auto-expand (when `preferExpanded`) is requested in
        // `updateUIViewController` via `experienceController.transition(to:)`,
        // once the controller is in the hierarchy. We never touch
        // `allowedExperiences` — it MUST include `.embedded` (excluding it is a
        // runtime fatal error).
        #endif

        return controller
    }

    /// Put the app in the `.playback` audio category so video has sound even
    /// when the ring/silent switch is on, and so PiP / background audio work.
    ///
    /// **visionOS is excluded on purpose.** Reports came in (June 2026) that
    /// configuring an explicit audio session category on Vision Pro made
    /// `AVPlayer` refuse to start playback — every title flipped straight to
    /// `failed`. visionOS's spatial audio engine prefers to manage its own
    /// session; explicit `.playback` here fights it. iOS still needs the
    /// override (otherwise the ring/silent switch mutes video); tvOS keeps it
    /// for parity. If the symptom returns on visionOS in a future OS, revisit
    /// with `.ambient` mode rather than blanket-skipping.
    private func configureAudioSession() {
        #if os(iOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
        #endif
    }

    /// Player teardown (the view was dismissed): stop the player and **release
    /// the `.playback` audio session** so the app drops its background-audio
    /// assertion and can be suspended — otherwise the session stays active after
    /// playback ends and keeps the app awake (battery / heat). `.notifyOthers…`
    /// lets other apps' audio resume.
    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        controller.player?.pause()
        #if os(iOS) || os(tvOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        context.coordinator.onDismiss = onDismiss
        if controller.player !== player {
            controller.player = player
        }
        #if os(visionOS)
        // Keep the cinema control closures current (the representable is recreated
        // on SwiftUI updates). Titles only change via a cycle handler, which
        // re-applies the actions itself, so we don't rebuild them here.
        context.coordinator.cinemaControls = cinemaControls
        // Auto-expand once, after the controller is in the hierarchy: transition
        // to the expanded experience so it docks into the open immersive space
        // without a manual tap on the system expand control. (Documented AVKit
        // API — `transition(to:)`; does NOT touch `allowedExperiences`, which
        // must always include `.embedded`.)
        if preferExpanded, !context.coordinator.didRequestExpand {
            context.coordinator.didRequestExpand = true
            Task { @MainActor in
                _ = await controller.experienceController.transition(to: .expanded)
            }
        }

        // Re-dock on a size/seat change: the docking region was already updated
        // (DarkTheaterView bumped the token *after* applying it), so a quick
        // `.embedded` → `.expanded` round-trip makes the system re-fit the
        // docked screen to the new size/position. Skip until we've expanded once
        // (nothing to re-dock before then) and only act on a *new* token.
        if let redockToken, redockToken != context.coordinator.lastRedockToken {
            context.coordinator.lastRedockToken = redockToken
            // Only after the initial expand (nothing to re-dock before then). The
            // token is non-nil only once the user changes size/seat in-cinema, so
            // this fires on the first such change, not on entry.
            if context.coordinator.didRequestExpand {
                Task { @MainActor in
                    _ = await controller.experienceController.transition(to: .embedded)
                    _ = await controller.experienceController.transition(to: .expanded)
                }
            }
        }
        #endif
    }

    /// Small holder for the dismiss closure (used by the visionOS "Back"
    /// contextual action) and the one-shot expand guard. We don't implement
    /// `AVPlayerViewControllerDelegate`: its dismissal-transition callback is
    /// unavailable across iOS / tvOS / visionOS in this SDK, and the exit paths
    /// are already covered (Back action, `.onExitCommand`, `PlayerView`'s
    /// end-of-playback observer, and `onDisappear`).
    final class Coordinator {
        var onDismiss: () -> Void
        /// Guards the one-shot expand transition (Cinema Mode).
        var didRequestExpand = false
        /// Last re-dock token acted on, so each size/seat change re-docks once.
        var lastRedockToken: UUID?
        #if os(visionOS)
        /// The docked-player controller, so a cycler can re-set the contextual
        /// actions with a refreshed title after changing size/seat.
        weak var controller: AVPlayerViewController?
        /// Cinema size/seat bridge; `nil` for windowed playback (Back-only).
        var cinemaControls: CinemaControlBinding?

        /// Build the transport-bar contextual actions — `Back`, plus the live
        /// Screen-size + Seat cyclers when in Cinema — and set them on the
        /// controller. Each cycler re-invokes this so its button title reflects
        /// the new value. Idempotent; safe to call repeatedly.
        @MainActor
        func applyContextualActions() {
            guard let controller else { return }
            var actions = [
                UIAction(
                    title: "Back",
                    image: UIImage(systemName: "chevron.backward")
                ) { [weak self] _ in
                    self?.dismiss()
                }
            ]
            if let controls = cinemaControls {
                actions.append(UIAction(
                    title: "Screen · \(controls.sizeTitle())",
                    image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")
                ) { [weak self] _ in
                    controls.cycleSize()
                    self?.applyContextualActions()
                })
                actions.append(UIAction(
                    title: "Seat · \(controls.seatTitle())",
                    image: UIImage(systemName: "chair.lounge")
                ) { [weak self] _ in
                    controls.cycleSeat()
                    self?.applyContextualActions()
                })
            }
            controller.contextualActions = actions
        }
        #endif

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
        }

        @MainActor
        func dismiss() {
            onDismiss()
        }
    }
}
