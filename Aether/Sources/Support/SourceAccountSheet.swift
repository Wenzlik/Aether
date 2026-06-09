import SwiftUI
import AetherCore

/// Detail sheet for a connected media source, opened from the compact Account
/// rows in Settings. Surfaces the things that used to sit permanently on the
/// Settings screen — server, connection status, and the destructive **Sign Out**
/// — behind a tap, so the main screen stays calm (§1/§2 of the Settings feedback).
struct SourceAccountSheet: View {
    let title: String
    let serverName: String?
    let status: AetherStatus
    /// True when this source is connected but not the active one (and more than
    /// one source is connected) — i.e. switching to it is meaningful (#224).
    var canSetActive: Bool = false
    let isSigningOut: Bool
    var onSetActive: (() -> Void)? = nil
    let onSignOut: () -> Void
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                Text(title)
                    .font(AetherDesign.Typography.heroTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)

                AetherSettingsSection("Connection") {
                    AetherSettingsRow(label: "Status", status: status)
                    if let serverName {
                        AetherSettingsRow(label: "Server", value: serverName)
                    }
                }

                if canSetActive, let onSetActive {
                    AetherSettingsSection("Library") {
                        AetherSettingsRow(
                            label: "Set as Active Source",
                            description: "Browse this server in your Library.",
                            actionRole: .primary,
                            action: onSetActive
                        )
                    }
                }

                AetherSettingsSection("Account") {
                    AetherSettingsRow(
                        label: isSigningOut ? "Signing out…" : "Sign Out",
                        actionRole: .destructive,
                        action: onSignOut
                    )
                    .disabled(isSigningOut)
                }
            }
            .padding(AetherDesign.Spacing.l)
            .frame(maxWidth: AetherSheetLayout.maxContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .tvOSScrollFocusable()
        }
        .aetherScreenBackground()
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
                    .padding(AetherDesign.Spacing.m)
            }
            .buttonStyle(.plain)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
