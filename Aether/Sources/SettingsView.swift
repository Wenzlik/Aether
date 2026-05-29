import SwiftUI
import AetherCore

/// Aether's settings surface — calm, factual, four short sections.
///
/// Account, Sources, Playback, About. Sign-out is the only destructive action;
/// everything else is read-only state. Sits inside a `ScrollView` rather than
/// a `Form` because `Form`'s grouped-table chrome fights Aether's dark
/// cinematic surfaces — see `docs/ux/DESIGN_PRINCIPLES.md` → *Settings language*.
struct SettingsView: View {
    @State var viewModel: SettingsViewModel
    @State private var isSigningOut = false

    var body: some View {
        ZStack {
            AetherDesign.Palette.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                    header

                    accountSection
                    sourcesSection
                    playbackSection
                    aboutSection
                }
                .padding(.horizontal, AetherDesign.Spacing.l)
                .padding(.top, AetherDesign.Spacing.l)
                .padding(.bottom, AetherDesign.Spacing.xxl)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlay(alignment: .topTrailing) { closeButton }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
            Text("Settings")
                .font(AetherDesign.Typography.heroTitle)
                .foregroundStyle(AetherDesign.Palette.textPrimary)
            Text("Manage your sources and your account.")
                .font(AetherDesign.Typography.metadata)
                .foregroundStyle(AetherDesign.Palette.textSecondary)
        }
    }

    // MARK: - Sections

    private var accountSection: some View {
        AetherSettingsSection("Account") {
            AetherSettingsRow(label: "Plex", value: viewModel.plexAccountLabel)
            if viewModel.isPlexSignedIn {
                AetherSettingsRow(
                    label: isSigningOut ? "Signing out…" : "Sign Out of Plex",
                    actionRole: .destructive
                ) {
                    Task { await performSignOut() }
                }
                .disabled(isSigningOut)
            }
        }
    }

    private var sourcesSection: some View {
        AetherSettingsSection("Sources") {
            AetherSettingsRow(label: "Plex", value: viewModel.plexSourceLabel)
            AetherSettingsRow(label: "Synology", value: viewModel.synologySourceLabel)
        }
    }

    private var playbackSection: some View {
        AetherSettingsSection("Playback") {
            AetherSettingsRow(label: "Direct Play", value: viewModel.directPlayLabel)
            AetherSettingsRow(label: "Transcoding", value: viewModel.transcodingLabel)
            AetherSettingsRow(label: "Offline Downloads", value: viewModel.offlineDownloadsLabel)
        }
    }

    private var aboutSection: some View {
        AetherSettingsSection("About") {
            AetherSettingsRow(label: viewModel.appName, value: nil)
            AetherSettingsRow(label: "Version", value: viewModel.versionString)
            AetherSettingsRow(label: "Build", value: viewModel.buildString)
            VStack(alignment: .leading, spacing: 0) {
                Text(viewModel.tagline)
                    .font(AetherDesign.Typography.caption)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
                    .padding(.vertical, AetherDesign.Spacing.s)
                    .padding(.horizontal, AetherDesign.Spacing.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Close

    private var closeButton: some View {
        Button {
            viewModel.dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AetherDesign.Palette.textSecondary)
                .padding(AetherDesign.Spacing.s)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .padding(AetherDesign.Spacing.m)
        .accessibilityLabel("Close settings")
    }

    // MARK: - Actions

    private func performSignOut() async {
        isSigningOut = true
        await viewModel.signOut()
        isSigningOut = false
    }
}
