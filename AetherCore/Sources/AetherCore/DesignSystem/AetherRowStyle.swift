import SwiftUI

/// A colour-coded status value shown on the trailing edge of a settings /
/// sources row, e.g. `Available` (green), `Not connected` (red), `Coming soon`
/// (grey). Replaces the old plain-grey value text so connection state reads at
/// a glance from couch distance — see `docs/ux/DESIGN_PRINCIPLES.md`.
public enum AetherStatus: Sendable, Equatable {
    /// Green — a capability is live (Available, Connected).
    case positive(String)
    /// Red — something the user could act on is not set up (Not connected).
    case negative(String)
    /// Grey — informational, nothing to do yet (Coming soon).
    case muted(String)

    public static let available = AetherStatus.positive("Available")
    public static let connected = AetherStatus.positive("Connected")
    public static let notConnected = AetherStatus.negative("Not connected")
    public static let comingSoon = AetherStatus.muted("Coming soon")

    public var text: String {
        switch self {
        case let .positive(text), let .negative(text), let .muted(text):
            return text
        }
    }

    public var color: Color {
        switch self {
        case .positive: return AetherDesign.Palette.success
        case .negative: return AetherDesign.Palette.error
        case .muted:    return AetherDesign.Palette.textTertiary
        }
    }
}

/// Native tvOS focus treatment for list-style rows (settings cards, the audio
/// / subtitle pickers on Detail): a soft elevated fill, a small scale lift, and
/// a subtle shadow — driven entirely by the system focus engine, no borders or
/// focus hacks. On iOS / visionOS `\.isFocused` stays false so the row renders
/// flat, exactly like `AetherButton`.
///
/// Apply this *inside* a `Button`'s label (where tvOS populates `\.isFocused`),
/// then give the button `.buttonStyle(.plain)`.
struct AetherFocusRow: ViewModifier {
    var cornerRadius: CGFloat = AetherDesign.Radius.card

    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(AetherDesign.Palette.surfaceElevated)
                    .overlay {
                        // Faint violet wash + hairline so the focused row reads
                        // as "brand-selected", not just lighter grey.
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(AetherDesign.Palette.accent.opacity(0.14))
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(AetherDesign.Palette.accent.opacity(0.45), lineWidth: 1)
                    }
                    .opacity(isFocused ? 1 : 0)
            }
            // Soft violet glow instead of a flat black shadow.
            .shadow(color: AetherDesign.Palette.focusGlow.opacity(isFocused ? 0.45 : 0.0),
                    radius: isFocused ? 16 : 0,
                    y: isFocused ? 6 : 0)
            .scaleEffect(isFocused ? 1.02 : 1.0)
            .animation(AetherDesign.Motion.focus, value: isFocused)
    }
}

public extension View {
    /// Apply the standard tvOS focus lift used by Aether's row primitives.
    func aetherFocusRow(cornerRadius: CGFloat = AetherDesign.Radius.card) -> some View {
        modifier(AetherFocusRow(cornerRadius: cornerRadius))
    }
}
