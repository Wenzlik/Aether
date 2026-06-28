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
/// **Cinema controls live in the player's Info panel (visionOS).** Screen size +
/// seat are surfaced via `customInfoViewControllers` — the documented, Destination
/// Video–proven surface that renders as a tab in the native player's info panel,
/// reached by tapping the video, and that *rides along while the video is docked*
/// in the immersive cinema (the `.expanded` experience). This replaces an earlier
/// `contextualActions` attempt: per Apple's docs `contextualActions` is shown
/// **only while the transport bar is hidden** (so it vanished the moment the user
/// tapped to reveal the native controls) and is meant for transient single prompts
/// like "Skip Intro" — the wrong surface for a persistent two-axis menu.
/// `transportBarCustomMenuItems` (inline buttons by the scrubber) is tvOS-only and
/// unavailable on visionOS, so the Info panel is the supported placement. See
/// `CinemaInfoControls`. The hosting view controllers are built by `DetailView`
/// and passed in via `makeCinemaInfoControllers`; `nil` for windowed playback.
struct SystemVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    let onDismiss: () -> Void
    /// visionOS Cinema only: builds the `customInfoViewControllers` (Screen-size +
    /// Seat panel) for the player's info panel. A maker closure (not the built
    /// controllers) so they're constructed exactly once, in `makeUIViewController`.
    /// `nil` for windowed playback (no cinema tab).
    let makeCinemaInfoControllers: (() -> [UIViewController])?
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
    /// tvOS only: the single transient player prompt active right now (Skip Intro
    /// / Skip Credits / Play Next Episode), surfaced as a **focusable**
    /// `AVPlayerViewController` contextual action — the only surface that can take
    /// focus over the tvOS player (a SwiftUI overlay button can't, the player VC
    /// owns the remote). `nil` clears it. Unused on iOS / visionOS, which keep
    /// their working SwiftUI overlays. (#529)
    let contextualPromptTitle: String?
    let onContextualPrompt: (() -> Void)?

    init(
        player: AVPlayer,
        preferExpanded: Bool = false,
        redockToken: UUID? = nil,
        makeCinemaInfoControllers: (() -> [UIViewController])? = nil,
        contextualPromptTitle: String? = nil,
        onContextualPrompt: (() -> Void)? = nil,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.player = player
        self.preferExpanded = preferExpanded
        self.redockToken = redockToken
        self.makeCinemaInfoControllers = makeCinemaInfoControllers
        self.contextualPromptTitle = contextualPromptTitle
        self.onContextualPrompt = onContextualPrompt
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
        controller.contextualActions = [
            UIAction(
                title: "Back",
                image: UIImage(systemName: "chevron.backward")
            ) { [weak coordinator = context.coordinator] _ in
                coordinator?.dismiss()
            }
        ]
        // Cinema Screen-size + Seat controls as a tab in the player's Info panel
        // (`customInfoViewControllers`) — shown when the user taps the video and
        // opens the info panel, and persists while docked. Built once here.
        if let makeCinemaInfoControllers {
            controller.customInfoViewControllers = makeCinemaInfoControllers()
        }
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
        #if os(tvOS)
        // Drive the active player prompt (Skip Intro / Skip Credits / Play Next
        // Episode) as a focusable native contextual action — shown while the
        // transport bar is hidden, which is exactly when these prompts appear.
        // A SwiftUI overlay button can't take focus over the player VC (#529).
        context.coordinator.onContextualPrompt = onContextualPrompt
        if context.coordinator.currentPromptTitle != contextualPromptTitle {
            context.coordinator.currentPromptTitle = contextualPromptTitle
            if let contextualPromptTitle {
                controller.contextualActions = [
                    UIAction(
                        title: contextualPromptTitle,
                        image: UIImage(systemName: "forward.end.fill")
                    ) { [weak coordinator = context.coordinator] _ in
                        coordinator?.onContextualPrompt?()
                    }
                ]
            } else {
                controller.contextualActions = []
            }
        }
        #endif
        #if os(visionOS)
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
        /// tvOS: the current contextual-prompt action + the title it was built
        /// for, so the action is rebuilt only when the prompt changes (#529).
        var onContextualPrompt: (() -> Void)?
        var currentPromptTitle: String?

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
        }

        @MainActor
        func dismiss() {
            onDismiss()
        }
    }
}
