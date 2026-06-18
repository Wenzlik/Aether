import SwiftUI
import AetherCore

/// Shared visual language for the Mac app, matching the iOS app's dark,
/// cinematic look (#232): a deep vertical gradient behind content and the brand
/// accent as the app tint. Surfaces layer translucent material on top for the
/// glass feel.
enum AetherMacTheme {
    /// App-wide accent (brand blue) — drives buttons, sliders, selection.
    static let accent = AetherDesign.Palette.accent

    /// The cinematic background gradient used behind the library content.
    static var background: LinearGradient {
        LinearGradient(
            colors: [
                AetherDesign.Palette.background,
                AetherDesign.Palette.backgroundMid,
                AetherDesign.Palette.backgroundBottom
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

extension View {
    /// Place the cinematic gradient (with atmospheric blue/purple blooms) behind
    /// a scrollable content view and hide the system's opaque scroll background.
    func cinematicBackground() -> some View {
        scrollContentBackground(.hidden)
            .aetherScreenBackground()
    }
}
