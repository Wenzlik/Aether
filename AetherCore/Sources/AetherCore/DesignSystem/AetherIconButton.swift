import SwiftUI

/// The circular glyph used by the Detail screen's compact (tertiary) action row.
/// Exposed on its own so it can also label a `Menu` (Download / Source pickers)
/// and keep the same look. Lifts + glows on focus (tvOS) via `premiumFocus`.
public struct AetherIconCircleLabel: View {
    public let systemImage: String
    public var isActive: Bool

    public init(systemImage: String, isActive: Bool = false) {
        self.systemImage = systemImage
        self.isActive = isActive
    }

    /// Bigger, easier focus targets on tvOS; compact on touch / spatial.
    private var diameter: CGFloat {
        #if os(tvOS)
        return 66
        #else
        return 48
        #endif
    }

    public var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: diameter * 0.4, weight: .semibold))
            // Borderless (#382): no stroke ring on any platform. Active reads
            // through an accent-*filled* circle + white glyph — an unmistakable
            // "on" without the old border; inactive sits on a faint material
            // circle that keeps the ≥44pt hit target legible. tvOS focus is
            // still driven by `premiumFocus` (lift + glow), so the button stays
            // clearly focusable even though the static ring is gone.
            .foregroundStyle(isActive ? Color.white : AetherDesign.Palette.textPrimary)
            .frame(width: diameter, height: diameter)
            .background(
                isActive
                    ? AnyShapeStyle(AetherDesign.Palette.accent)
                    : AnyShapeStyle(AetherDesign.Materials.card),
                in: Circle()
            )
            .contentShape(Circle())
            .premiumFocus(scale: 1.12)
    }
}

/// A compact circular icon button — the tertiary action treatment on the Detail
/// screen (Download · Mark Watched · Source · Technical Details, etc.). A plain
/// `Button`, so it's focusable on tvOS and the whole row is reachable left/right
/// by the Siri Remote. Always carries an accessibility label since it's
/// icon-only.
public struct AetherIconButton: View {
    public let systemImage: String
    public let accessibilityLabel: String
    public var isActive: Bool
    public let action: () -> Void

    public init(
        systemImage: String,
        accessibilityLabel: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.isActive = isActive
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            #if os(tvOS)
            // tvOS: reveal the (otherwise icon-only) action's name as a caption
            // beneath the glyph while focused — the Apple TV idiom for circular
            // controls, so a sighted user doesn't have to guess what "eye" / "info"
            // do. Rendered as an overlay so it never reflows the action row (#441).
            AetherIconCircleLabel(systemImage: systemImage, isActive: isActive)
                .modifier(IconFocusCaption(label: accessibilityLabel))
            #else
            AetherIconCircleLabel(systemImage: systemImage, isActive: isActive)
            #endif
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityLabel))
    }
}

#if os(tvOS)
/// Floats the button's label beneath the glyph while focused. An overlay (not a
/// stacked `VStack`) so the caption appearing/disappearing never shifts the row's
/// layout; only the focused button shows its caption.
private struct IconFocusCaption: ViewModifier {
    let label: String
    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            Text(label)
                .font(AetherDesign.Typography.caption)
                .foregroundStyle(AetherDesign.Palette.textSecondary)
                .lineLimit(1)
                .fixedSize()
                .opacity(isFocused ? 1 : 0)
                .offset(y: 26)
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: 0.15), value: isFocused)
        }
    }
}
#endif
