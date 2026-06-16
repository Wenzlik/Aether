import SwiftUI

/// Aether's one button. Three roles, one shape, one motion.
///
/// - `.primary` is the affirmative action on a screen (Play, Done, Sign in).
///   There should be at most one primary button visible at a time.
/// - `.secondary` is a low-emphasis alternative (Cancel, Close, See all).
/// - `.destructive` warns: Sign out, Remove, Delete cache. Tinted red.
///
/// On tvOS each role lifts on focus (1.05 scale + soft shadow + accent
/// strengthen). On iOS / visionOS the focused branch collapses since there is
/// no focus engine driving `\.isFocused`.
public struct AetherButton: View {
    public enum Role: Sendable {
        case primary
        case secondary
        case destructive
    }

    public let title: String
    public let systemImage: String?
    public let role: Role
    public let action: () -> Void

    public init(
        _ title: String,
        systemImage: String? = nil,
        role: Role = .primary,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            AetherButtonLabel(title: title, systemImage: systemImage, role: role)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Label

/// Pulled out so the focused state environment is read inside `Button`'s
/// content, where tvOS actually populates `\.isFocused`. Public so a
/// `NavigationLink` can wear the exact same pill (the Detail "Play S1E1" show
/// action, #382) — a link, not a `Button`, but visually one `AetherButton`.
public struct AetherButtonLabel: View {
    let title: String
    let systemImage: String?
    let role: AetherButton.Role

    public init(title: String, systemImage: String? = nil, role: AetherButton.Role) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
    }

    @Environment(\.isFocused) private var isFocused

    public var body: some View {
        HStack(spacing: AetherDesign.Spacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(LocalizedStringKey(title))   // localize static labels (#312)
        }
        .font(AetherDesign.Typography.cardTitle)
        .padding(.horizontal, AetherDesign.Spacing.l)
        .padding(.vertical, AetherDesign.Spacing.s)
        .background(background)
        .clipShape(Capsule())
        .foregroundStyle(foreground)
        // Permanent soft bloom under the primary action so it reads as the hero
        // CTA even unfocused; the focused lift + blue glow come from
        // `premiumFocus` (one focus treatment everywhere — no borders).
        .shadow(color: AetherDesign.Palette.focusGlow.opacity(role == .primary && !isFocused ? 0.25 : 0.0),
                radius: role == .primary && !isFocused ? 10 : 0)
        .premiumFocus(scale: 1.04)
    }

    @ViewBuilder
    private var background: some View {
        switch role {
        case .primary:
            // The hero action wears the aurora gradient; it brightens on focus.
            AetherDesign.Gradients.aurora
                .opacity(isFocused ? 1.0 : 0.85)
        case .secondary:
            AetherDesign.Palette.surface.opacity(isFocused ? 1.0 : 0.6)
        case .destructive:
            AetherDesign.Palette.error.opacity(isFocused ? 0.40 : 0.18)
        }
    }

    private var foreground: Color {
        switch role {
        case .primary:     return Color.white
        case .secondary:   return AetherDesign.Palette.textPrimary
        case .destructive: return AetherDesign.Palette.error
        }
    }
}

#if DEBUG
struct AetherButton_Previews: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            AetherButton("Play", systemImage: "play.fill") {}
            AetherButton("Try again", role: .secondary) {}
            AetherButton("Sign Out of Plex", role: .destructive) {}
        }
        .padding(AetherDesign.Spacing.l)
        .background(AetherDesign.Palette.background)
        .previewLayout(.sizeThatFits)
    }
}
#endif
