import SwiftUI
import AppKit
import AetherCore

/// Cold-launch splash for the macOS app — the Infuse-style "the app comes
/// alive" moment. The app glyph scales in over the cinematic background, holds
/// with a soft breathing glow, then fades to reveal the library underneath.
///
/// Pure app-target view glue (macOS only); no `AetherCore` changes. The mark is
/// the **live application icon** (`NSApp.applicationIconImage`) rather than a
/// bundled asset, so the splash always matches the actual app icon and adds no
/// files to maintain. The background reuses `aetherScreenBackground()` so the
/// hand-off to the library is seamless — no colour shift when it fades.
///
/// Shown **once per process** via ``LaunchSplashGate`` (cold launch only);
/// reopening the library window later in the same session does not replay it.
struct MacLaunchSplash: View {
    /// Called when the exit animation has finished, so the host can drop the
    /// overlay from the hierarchy entirely.
    var onFinished: () -> Void

    /// Entrance → hold → exit state machine. Each case drives `scale`/`opacity`.
    private enum Phase { case start, settled, leaving }

    @State private var phase: Phase = .start
    /// Drives the breathing glow during the hold; animated as a repeating ramp.
    @State private var glowBreathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How long the mark stays fully settled before the fade-out begins.
    private let holdDuration: Duration = .milliseconds(950)
    /// Length of the fade-out — the window's content is revealed across this.
    private let fadeDuration: Duration = .milliseconds(400)

    var body: some View {
        ZStack {
            // Opaque from frame 0 so the library never flashes behind the mark.
            Color.clear.aetherScreenBackground()
            mark
        }
        .ignoresSafeArea()
        .opacity(phase == .leaving ? 0 : 1)
        .allowsHitTesting(false)            // never intercepts clicks
        .task { await run() }
    }

    private var mark: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: 168, height: 168)
            .scaleEffect(scale)
            .opacity(phase == .start ? 0 : 1)
            // Soft brand-blue bloom behind the glyph; breathes during the hold.
            .shadow(
                color: AetherDesign.Palette.accent.opacity(glowBreathing ? 0.55 : 0.28),
                radius: glowBreathing ? 40 : 24
            )
    }

    private var scale: CGFloat {
        guard !reduceMotion else { return 1 }
        switch phase {
        case .start:   return 0.86          // arrives slightly small
        case .settled: return 1.0
        case .leaving: return 1.04          // gentle push as it leaves
        }
    }

    @MainActor private func run() async {
        if reduceMotion {
            // No scale/pulse — just a calm cross-fade in, hold, fade out.
            withAnimation(.easeIn(duration: 0.25)) { phase = .settled }
        } else {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) {
                phase = .settled
            }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                glowBreathing = true
            }
        }

        try? await Task.sleep(for: holdDuration)
        withAnimation(.easeInOut(duration: fadeDuration.fractionalSeconds)) {
            phase = .leaving
        }
        try? await Task.sleep(for: fadeDuration)
        onFinished()
    }
}

private extension Duration {
    /// The duration as fractional seconds, for `withAnimation` which takes a
    /// `TimeInterval` rather than a `Duration`.
    var fractionalSeconds: TimeInterval {
        let (secs, atto) = components
        return TimeInterval(secs) + TimeInterval(atto) / 1e18
    }
}

// MARK: - One-shot host

/// Process-wide guard so only the first (cold-launch) window shows the splash.
/// Touched exclusively on the main thread during SwiftUI view construction —
/// `nonisolated(unsafe)` is the sanctioned Swift 6 escape hatch for that.
private enum LaunchSplashGate {
    nonisolated(unsafe) static var claimed = false

    /// Returns `true` exactly once per process; every later call returns `false`.
    static func claimOnce() -> Bool {
        if claimed { return false }
        claimed = true
        return true
    }
}

private struct MacLaunchSplashModifier: ViewModifier {
    // Evaluated once when the host view is first created → claims the splash for
    // the cold-launch window only. Re-creations keep the stored value.
    @State private var show = LaunchSplashGate.claimOnce()

    func body(content: Content) -> some View {
        content.overlay {
            if show {
                MacLaunchSplash(onFinished: { show = false })
                    .transition(.opacity)
            }
        }
    }
}

extension View {
    /// Overlay the macOS cold-launch splash. Shown once per process; a no-op on
    /// every window after the first.
    func macLaunchSplash() -> some View {
        modifier(MacLaunchSplashModifier())
    }
}
