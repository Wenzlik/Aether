import SwiftUI
import AetherCore

/// Aether's settings surface — a full-screen tab destination (no longer a
/// modal). Calm, factual, four grouped focusable cards: Account, Sources,
/// Playback, About. Status values are colour-coded (Available / Not connected /
/// Coming soon) so connection state reads at couch distance. Sign-out is the
/// only destructive action. See `docs/ux/DESIGN_PRINCIPLES.md` → *Settings*.
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
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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
            AetherSettingsRow(
                label: "Plex",
                systemImage: "play.circle.fill",
                status: viewModel.plexAccountStatus,
                action: viewModel.isPlexSignedIn ? nil : { viewModel.connect() }
            )

            if let serverDetail = viewModel.connectedServerDetail {
                AetherSettingsRow(label: serverDetail, systemImage: "server.rack", value: nil)
            }

            if viewModel.isPlexSignedIn {
                AetherSettingsRow(
                    label: isSigningOut ? "Signing out…" : "Sign Out of Plex",
                    systemImage: "rectangle.portrait.and.arrow.right",
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
            AetherSettingsRow(
                label: "Plex",
                systemImage: "play.circle.fill",
                status: viewModel.plexSourceStatus,
                action: viewModel.isPlexSignedIn ? nil : { viewModel.connect() }
            )
            AetherSettingsRow(label: "Synology", systemImage: "externaldrive.fill", status: viewModel.synologyStatus)
        }
    }

    private var playbackSection: some View {
        AetherSettingsSection("Playback") {
            AetherSettingsRow(label: "Direct Play", systemImage: "play.rectangle.fill", status: viewModel.directPlayStatus)
            AetherSettingsRow(label: "Transcoding", systemImage: "slider.horizontal.3", status: viewModel.transcodingStatus)
            AetherSettingsRow(label: "Offline Downloads", systemImage: "arrow.down.circle.fill", status: viewModel.offlineDownloadsStatus)
        }
    }

    private var aboutSection: some View {
        AetherSettingsSection("About") {
            AetherSettingsRow(label: viewModel.appName, systemImage: "info.circle.fill", value: nil)
            AetherSettingsRow(label: "Version", value: viewModel.versionString)
            AetherSettingsRow(label: "Build", value: viewModel.buildString)
            VStack(alignment: .leading, spacing: 0) {
                Text(viewModel.tagline)
                    .font(AetherDesign.Typography.caption)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
                    .padding(.vertical, AetherDesign.Spacing.m)
                    .padding(.horizontal, AetherDesign.Spacing.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Actions

    private func performSignOut() async {
        isSigningOut = true
        await viewModel.signOut()
        isSigningOut = false
    }
}
