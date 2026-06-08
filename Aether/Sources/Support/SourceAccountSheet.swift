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
    let isSigningOut: Bool
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
