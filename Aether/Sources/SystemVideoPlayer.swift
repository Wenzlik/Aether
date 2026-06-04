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
struct SystemVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    let onDismiss: () -> Void
    /// visionOS only: when `true`, request the **expanded** experience once the
    /// controller is in the hierarchy, so the player auto-docks into the open
    /// immersive space without the user tapping the expand control. Used by
    /// Cinema Mode; windowed playback leaves it `false`.
    let preferExpanded: Bool

    init(player: AVPlayer, preferExpanded: Bool = false, onDismiss: @escaping () -> Void = {}) {
        self.player = player
        self.preferExpanded = preferExpanded
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

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        context.coordinator.onDismiss = onDismiss
        if controller.player !== player {
            controller.player = player
        }
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

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
        }

        @MainActor
        func dismiss() {
            onDismiss()
        }
    }
}
