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
    /// Optional muted second line under the label — a short explanation of what
    /// the setting does ("Choose how Aether appears on your Home Screen").
    public let description: String?
    public let systemImage: String?
    public let style: Style
    public let action: (() -> Void)?

    public init(
        label: String,
        description: String? = nil,
        systemImage: String? = nil,
        value: String?,
        action: (() -> Void)? = nil
    ) {
        self.label = label
        self.description = description
        self.systemImage = systemImage
        self.style = .value(value)
        self.action = action
    }

    public init(
        label: String,
        description: String? = nil,
        systemImage: String? = nil,
        status: AetherStatus,
        action: (() -> Void)? = nil
    ) {
        self.label = label
        self.description = description
        self.systemImage = systemImage
        self.style = .status(status)
        self.action = action
    }

    public init(
        label: String,
        description: String? = nil,
        systemImage: String? = nil,
        actionRole: ActionRole,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.description = description
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

            VStack(alignment: .leading, spacing: 2) {
                // `LocalizedStringKey(_:)` over the String params: a static label
                // ("Theme") resolves from the catalog (#312), while dynamic text
                // (server name, "80%") isn't a key so it falls back to itself —
                // localizes the chrome without changing the public String API.
                Text(LocalizedStringKey(label))
                    .font(AetherDesign.Typography.body)
                    .foregroundStyle(labelColor)
                if let description {
                    Text(LocalizedStringKey(description))
                        .font(AetherDesign.Typography.caption)
                        .foregroundStyle(AetherDesign.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: AetherDesign.Spacing.s)

            switch style {
            case let .value(value):
                if let value {
                    // Truncate, never expand: a long value (server name, OS/build
                    // string, capacity) used to push the row wider than an iPhone,
                    // which made the whole Settings page pan sideways (#248).
                    Text(LocalizedStringKey(value))
                        .font(AetherDesign.Typography.metadata)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            case let .status(status):
                Text(LocalizedStringKey(status.text))
                    .font(AetherDesign.Typography.metadata)
                    .foregroundStyle(status.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
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

    /// Headerless variant — renders the card without a section label above it.
    public init(@ViewBuilder content: @escaping () -> Content) {
        self.title = ""
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.s) {
            if !title.isEmpty {
            Text(LocalizedStringKey(title))
                .textCase(.uppercase)   // localize the key, then uppercase (#312)
                .font(AetherDesign.Typography.caption)
                .foregroundStyle(AetherDesign.Palette.textTertiary)
                .tracking(0.6)
                .padding(.horizontal, AetherDesign.Spacing.m)
            }

            // Hairline separators between rows, inset from the leading edge — so
            // a grouped card reads like an iOS inset-grouped list instead of one
            // undivided block (the rows used to blur together). `_VariadicView`
            // inserts the dividers between the builder's rows, so call sites
            // don't each have to.
            _VariadicView.Tree(DividedRows()) {
                content()
            }
            // Translucent frosted card over the cinematic background (tvOS 26 /
            // visionOS material), with a hairline so it still reads as a card.
            .background(AetherDesign.Materials.card, in: RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                    .strokeBorder(AetherDesign.Palette.separator, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous))
        }
    }
}

/// Inserts hairline separators between a section's rows (iOS inset-grouped
/// style — inset from the leading edge, none after the last row).
private struct DividedRows: _VariadicView_MultiViewRoot {
    @ViewBuilder
    func body(children: _VariadicView.Children) -> some View {
        let lastID = children.last?.id
        VStack(spacing: 0) {
            ForEach(children) { child in
                child
                if child.id != lastID {
                    Divider()
                        .overlay(AetherDesign.Palette.separator)
                        .padding(.leading, AetherDesign.Spacing.m)
                }
            }
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
