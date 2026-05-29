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
/// content, where tvOS actually populates `\.isFocused`.
private struct AetherButtonLabel: View {
    let title: String
    let systemImage: String?
    let role: AetherButton.Role

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: AetherDesign.Spacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(title)
        }
        .font(AetherDesign.Typography.cardTitle)
        .padding(.horizontal, AetherDesign.Spacing.l)
        .padding(.vertical, AetherDesign.Spacing.s)
        .background(background, in: Capsule())
        .foregroundStyle(foreground)
        .shadow(color: .black.opacity(isFocused ? 0.40 : 0.0),
                radius: isFocused ? 16 : 0,
                y: isFocused ? 8 : 0)
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .animation(AetherDesign.Motion.focus, value: isFocused)
    }

    private var background: Color {
        switch role {
        case .primary:
            return AetherDesign.Palette.accent.opacity(isFocused ? 0.45 : 0.22)
        case .secondary:
            return AetherDesign.Palette.surface.opacity(isFocused ? 1.0 : 0.6)
        case .destructive:
            return Color.red.opacity(isFocused ? 0.40 : 0.18)
        }
    }

    private var foreground: Color {
        switch role {
        case .primary, .secondary:
            return AetherDesign.Palette.textPrimary
        case .destructive:
            return Color.red.opacity(0.95)
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
