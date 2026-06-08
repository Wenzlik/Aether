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
            .foregroundStyle(isActive ? AetherDesign.Palette.accent : AetherDesign.Palette.textPrimary)
            .frame(width: diameter, height: diameter)
            .background(AetherDesign.Materials.card, in: Circle())
            .overlay {
                Circle().strokeBorder(
                    isActive ? AetherDesign.Palette.accent : AetherDesign.Palette.separator,
                    lineWidth: isActive ? 2 : 1
                )
            }
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
            AetherIconCircleLabel(systemImage: systemImage, isActive: isActive)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityLabel))
    }
}
