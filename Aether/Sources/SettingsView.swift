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
    @State private var isSigningOutJellyfin = false

    var body: some View {
        ZStack {
            AetherDesign.Gradients.background.ignoresSafeArea()

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

    /// Settings hero: the medium wordmark, the page label, the version
    /// (small, muted) — the brand mark replaces the previous gradient-text
    /// rendering so the identity is consistent with Library and Welcome.
    private var header: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
            AetherWordmark(.medium)
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xxs) {
                Text("Settings")
                    .font(AetherDesign.Typography.sectionTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                Text("Version \(viewModel.versionString) · Manage your sources and your account.")
                    .font(AetherDesign.Typography.caption)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
            }
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

            if viewModel.isJellyfinSignedIn {
                AetherSettingsRow(
                    label: "Jellyfin",
                    systemImage: "rectangle.stack.badge.play.fill",
                    status: .connected
                )
                if let name = viewModel.jellyfinServerName {
                    AetherSettingsRow(label: "Server: \(name)", systemImage: "server.rack", value: nil)
                }
                AetherSettingsRow(
                    label: isSigningOutJellyfin ? "Signing out…" : "Sign Out of Jellyfin",
                    systemImage: "rectangle.portrait.and.arrow.right",
                    actionRole: .destructive
                ) {
                    Task { await performSignOutJellyfin() }
                }
                .disabled(isSigningOutJellyfin)
            }
        }
    }

    private var sourcesSection: some View {
        AetherSettingsSection("Sources") {
            sourceRow(
                kind: .plex,
                label: "Plex",
                glyph: "play.circle.fill",
                connected: viewModel.isPlexSignedIn,
                connect: { viewModel.connect() }
            )
            sourceRow(
                kind: .jellyfin,
                label: "Jellyfin",
                glyph: "rectangle.stack.badge.play.fill",
                connected: viewModel.isJellyfinSignedIn,
                connect: { viewModel.connectJellyfin() }
            )
            AetherSettingsRow(label: "Synology", systemImage: "externaldrive.fill", status: viewModel.synologyStatus)
        }
    }

    /// One source row: tap to connect when disconnected, or — when both sources
    /// are connected — tap to make this the active (browsed) source. The active
    /// one reads "Active".
    private func sourceRow(
        kind: AppSession.SourceKind,
        label: String,
        glyph: String,
        connected: Bool,
        connect: @escaping () -> Void
    ) -> AetherSettingsRow {
        let status: AetherStatus
        if !connected {
            status = .notConnected
        } else if viewModel.canSwitchSources {
            status = viewModel.isActiveSource(kind) ? .positive("Active") : .connected
        } else {
            status = .connected
        }

        let action: (() -> Void)?
        if !connected {
            action = connect
        } else if viewModel.canSwitchSources && !viewModel.isActiveSource(kind) {
            action = { viewModel.setActive(kind) }
        } else {
            action = nil
        }

        return AetherSettingsRow(label: label, systemImage: glyph, status: status, action: action)
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

    private func performSignOutJellyfin() async {
        isSigningOutJellyfin = true
        await viewModel.signOutOfJellyfin()
        isSigningOutJellyfin = false
    }
}
