import SwiftUI

/// One row of an Aether settings section.
///
/// Two reading modes:
/// - **value row** — `label` left, `value` right; optional `accessory` glyph
///   for taps that open something. No animation, no spinner.
/// - **action row** — `label` only with a `role` (`.primary` / `.destructive`);
///   the whole row is tappable.
///
/// Sits inside the calm vertical stack used by `SettingsView` rather than a
/// `Form` — `Form`'s default grouped-table styling fights Aether's dark
/// cinematic surfaces. See `docs/ux/DESIGN_PRINCIPLES.md` → *Settings language*.
public struct AetherSettingsRow: View {
    public enum Style: Sendable {
        case value(String?)
        case status(AetherStatus)
        case action(role: ActionRole)
    }

    public enum ActionRole: Sendable {
        case primary
        case destructive
    }

    public let label: String
    public let systemImage: String?
    public let style: Style
    public let action: (() -> Void)?

    public init(
        label: String,
        systemImage: String? = nil,
        value: String?,
        action: (() -> Void)? = nil
    ) {
        self.label = label
        self.systemImage = systemImage
        self.style = .value(value)
        self.action = action
    }

    public init(
        label: String,
        systemImage: String? = nil,
        status: AetherStatus,
        action: (() -> Void)? = nil
    ) {
        self.label = label
        self.systemImage = systemImage
        self.style = .status(status)
        self.action = action
    }

    public init(
        label: String,
        systemImage: String? = nil,
        actionRole: ActionRole,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.systemImage = systemImage
        self.style = .action(role: actionRole)
        self.action = action
    }

    public var body: some View {
        if let action {
            Button(action: action) {
                content.aetherFocusRow()
            }
            .buttonStyle(.plain)
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        HStack(spacing: AetherDesign.Spacing.m) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(AetherDesign.Typography.body)
                    .foregroundStyle(AetherDesign.Palette.accent)
                    .frame(width: 28)
            }

            Text(label)
                .font(AetherDesign.Typography.body)
                .foregroundStyle(labelColor)

            Spacer(minLength: AetherDesign.Spacing.s)

            switch style {
            case let .value(value):
                if let value {
                    Text(value)
                        .font(AetherDesign.Typography.metadata)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                }
            case let .status(status):
                Text(status.text)
                    .font(AetherDesign.Typography.metadata)
                    .foregroundStyle(status.color)
            case .action:
                EmptyView()
            }

            if action != nil, case .value = style {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
            }
        }
        .padding(.vertical, AetherDesign.Spacing.m)
        .padding(.horizontal, AetherDesign.Spacing.m)
        .contentShape(Rectangle())
    }

    private var labelColor: Color {
        switch style {
        case .value, .status:
            return AetherDesign.Palette.textPrimary
        case let .action(role):
            switch role {
            case .primary:     return AetherDesign.Palette.textPrimary
            case .destructive: return Color.red.opacity(0.95)
            }
        }
    }
}

/// A single section of `AetherSettingsRow`s — header + rounded surface.
public struct AetherSettingsSection<Content: View>: View {
    public let title: String
    @ViewBuilder public let content: () -> Content

    public init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.s) {
            Text(title.uppercased())
                .font(AetherDesign.Typography.caption)
                .foregroundStyle(AetherDesign.Palette.textTertiary)
                .tracking(0.6)
                .padding(.horizontal, AetherDesign.Spacing.m)

            VStack(spacing: 0) {
                content()
            }
            .background(AetherDesign.Palette.surface, in: RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous))
        }
    }
}

#if DEBUG
struct AetherSettingsRow_Previews: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
            AetherSettingsSection("Account") {
                AetherSettingsRow(label: "Plex", value: "Connected as Home")
                AetherSettingsRow(label: "Sign Out of Plex", actionRole: .destructive) {}
            }

            AetherSettingsSection("Sources") {
                AetherSettingsRow(label: "Plex", value: "Connected")
                AetherSettingsRow(label: "Synology", value: "Coming soon")
            }
        }
        .padding(AetherDesign.Spacing.l)
        .background(AetherDesign.Palette.background)
        .previewLayout(.sizeThatFits)
    }
}
#endif
