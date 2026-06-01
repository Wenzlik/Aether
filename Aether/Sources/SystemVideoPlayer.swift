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
/// **Dismiss surface.** On tvOS the "Done" button is wired into the native
/// chrome via `contextualActions`, so it auto-hides with the rest of the
/// transport. (`contextualActions` is tvOS-only — iOS / visionOS use
/// `PlayerView`'s auto-hiding overlay xmark instead.) On tvOS the Menu
/// button on the Siri Remote remains the primary dismiss; `Done` is a
/// redundant fall-through.
///
/// Used on iOS, tvOS, and visionOS (all have UIKit + AVKit).
struct SystemVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    let onClose: @MainActor () -> Void

    init(player: AVPlayer, onClose: @escaping @MainActor () -> Void = {}) {
        self.player = player
        self.onClose = onClose
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        configureAudioSession()

        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        #if os(iOS) || os(visionOS)
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.videoGravity = .resizeAspect
        #endif

        #if os(tvOS)
        let close = UIAction(
            title: "Done",
            image: UIImage(systemName: "xmark")
        ) { _ in
            onClose()
        }
        controller.contextualActions = [close]
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
        if controller.player !== player {
            controller.player = player
        }
    }
}
