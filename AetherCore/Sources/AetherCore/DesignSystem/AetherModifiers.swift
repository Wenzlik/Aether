import SwiftUI

/// Shared view modifiers for the 0.6.0 UX refresh — the few cross-cutting
/// treatments every screen should share so platforms read as one product:
/// the cinematic screen background, the hero scrim, and the premium focus
/// (lift + glow, no borders). See `docs/next-steps/ux-refresh-060.md`.

public extension View {
    /// The standard full-screen cinematic background — the layered gradient +
    /// faint brand blooms (`AetherDesign.Gradients.background`), ignoring the
    /// safe area. Apply on every root screen body so navigating between screens
    /// never shows a background shift (and pure-black screens gain depth).
    ///
    /// > Do **not** apply behind full-screen video (the player stays pure black
    /// > so nothing competes with the picture).
    func aetherScreenBackground() -> some View {
        background(AetherDesign.Gradients.background.ignoresSafeArea())
    }

    /// Fades artwork into the page below it — a bottom-anchored scrim from clear
    /// to the background colour. Tokenises the hero backdrop fade so Detail and
    /// any future hero use the same ramp.
    func aetherHeroScrim() -> some View {
        overlay(alignment: .bottom) {
            LinearGradient(
                colors: [
                    Color.clear,
                    AetherDesign.Palette.background.opacity(0.55),
                    AetherDesign.Palette.background.opacity(0.96)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
    }

    /// Premium focus treatment — **depth, not an outline**. A focused element
    /// lifts (`scale`) and casts a soft blue glow; unfocused it's flat. Replaces
    /// the old stroke-border / fill-wash focus across cards, buttons, and rows
    /// for an Apple TV+ / Infuse feel.
    ///
    /// Cards earn a larger lift (they're physically bigger); buttons and rows
    /// use the smaller default. On iOS / iPadOS / visionOS `\.isFocused` stays
    /// `false` inside button labels, so this collapses to identity with no
    /// `#if` needed.
    func premiumFocus(scale: CGFloat = 1.04) -> some View {
        modifier(PremiumFocus(scale: scale))
    }
}

/// Lift-and-glow focus. Kept as a concrete `ViewModifier` so it can read the
/// focus environment and animate the transition with the shared `Motion.focus`.
public struct PremiumFocus: ViewModifier {
    private let scale: CGFloat
    @Environment(\.isFocused) private var isFocused

    public init(scale: CGFloat = 1.04) {
        self.scale = scale
    }

    public func body(content: Content) -> some View {
        content
            .shadow(
                color: AetherDesign.Palette.focusGlow.opacity(isFocused ? 0.6 : 0.0),
                radius: isFocused ? 20 : 0,
                y: isFocused ? 8 : 0
            )
            .scaleEffect(isFocused ? scale : 1.0)
            .animation(AetherDesign.Motion.focus, value: isFocused)
    }
}
