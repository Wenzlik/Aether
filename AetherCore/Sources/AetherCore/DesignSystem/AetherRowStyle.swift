import SwiftUI

/// A colour-coded status value shown on the trailing edge of a settings /
/// sources row, e.g. `Available` (green), `Not connected` (red), `Planned`
/// (grey). Replaces the old plain-grey value text so connection state reads at
/// a glance from couch distance — see `docs/ux/DESIGN_PRINCIPLES.md`.
public enum AetherStatus: Sendable, Equatable {
    /// Green — a capability is live (Available).
    case positive(String)
    /// Red — something the user could act on is not set up (Not connected).
    case negative(String)
    /// Grey — informational, nothing to do yet (Planned).
    case muted(String)
    /// Calm secondary text — a healthy steady state (Connected, Active, Signed
    /// in). Deliberately *not* green: users only need colour when something is
    /// wrong, so healthy states stay quiet and problem states (red) stand out.
    /// See #224 §4.
    case neutral(String)

    public static let available = AetherStatus.positive("Available")
    public static let connected = AetherStatus.neutral("Connected")
    public static let notConnected = AetherStatus.negative("Not connected")
    /// "Planned" reads calmer and more deliberate than "Coming soon" — the
    /// status the user lands on when a feature exists on the roadmap but
    /// isn't shippable yet. Same grey treatment.
    public static let comingSoon = AetherStatus.muted("Planned")

    public var text: String {
        switch self {
        case let .positive(text), let .negative(text), let .muted(text), let .neutral(text):
            return text
        }
    }

    public var color: Color {
        switch self {
        case .positive: return AetherDesign.Palette.success
        case .negative: return AetherDesign.Palette.error
        case .muted:    return AetherDesign.Palette.textTertiary
        case .neutral:  return AetherDesign.Palette.textSecondary
        }
    }
}

/// Native tvOS focus treatment for list-style rows (settings cards, the audio
/// / subtitle pickers on Detail). 0.6.0: a focused row **lifts and glows** —
/// the shared `premiumFocus` depth treatment — instead of painting an
/// accent-tinted box with a hairline border (which read like a dev build). A
/// neutral elevated fill keeps the focused row legible without colouring it.
/// On iOS / visionOS `\.isFocused` stays false so the row renders flat.
///
/// Apply this *inside* a `Button`'s label (where tvOS populates `\.isFocused`),
/// then give the button `.buttonStyle(.plain)`.
struct AetherFocusRow: ViewModifier {
    var cornerRadius: CGFloat = AetherDesign.Radius.card

    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content
            // Neutral elevated fill on focus (no accent wash, no border) so the
            // focused row reads clearly; depth comes from premiumFocus.
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(AetherDesign.Palette.surfaceElevated)
                    .opacity(isFocused ? 1 : 0)
            }
            .premiumFocus(scale: 1.04)
    }
}

public extension View {
    /// Apply the standard tvOS focus lift used by Aether's row primitives.
    func aetherFocusRow(cornerRadius: CGFloat = AetherDesign.Radius.card) -> some View {
        modifier(AetherFocusRow(cornerRadius: cornerRadius))
    }
}
