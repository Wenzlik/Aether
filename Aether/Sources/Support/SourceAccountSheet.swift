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
    /// True when more than one source is connected, so the "Active" concept is
    /// meaningful. Drives an explanatory footer clarifying that Active only sets
    /// what Library/Search *browse* — it doesn't reroute playback of titles that
    /// exist on several servers (those follow a fixed source preference; switch
    /// them per title on Detail). Shown even for the already-active source, where
    /// `canSetActive` is false (#525).
    var explainsActiveSource: Bool = false
    let isSigningOut: Bool
    var onSetActive: (() -> Void)? = nil
    /// When set, a **Choose Server** row is shown — for accounts that can reach
    /// more than one server (Plex, #323). Opens the server picker.
    var onChooseServer: (() -> Void)? = nil
    /// The active Plex Home profile's name, shown above "Switch Profile".
    var activeProfileName: String? = nil
    /// When set, a **Switch Profile** row is shown (Plex Home). Opens the profile picker.
    var onSwitchProfile: (() -> Void)? = nil
    /// Connected servers for a multi-server source (Jellyfin / Emby). When more
    /// than one is present, each is listed with a Remove action; a single server
    /// just shows the "Server" row above.
    var servers: [ConnectedServer] = []
    var onRemoveServer: ((String) -> Void)? = nil
    let onSignOut: () -> Void
    let onClose: () -> Void

    // Robust close: binding dismissal via `onClose` is unreliable on iOS with
    // many stacked `.sheet`s (SettingsView) — `dismiss()` always closes.
    @Environment(\.dismiss) private var dismiss

    struct ConnectedServer: Identifiable, Equatable {
        let id: String
        let name: String
    }

    /// Sign Out is destructive and easy to hit by accident — gate it behind a
    /// confirmation (#441), matching the tvOS source-detail screen.
    @State private var confirmSignOut = false

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
                    if let onChooseServer {
                        AetherSettingsRow(
                            label: "Manage Servers",
                            description: "Turn servers on your account on or off — content from several is merged.",
                            systemImage: "rack",
                            value: nil,
                            action: onChooseServer
                        )
                    }
                }

                if servers.count > 1, let onRemoveServer {
                    AetherSettingsSection("Servers") {
                        ForEach(servers) { server in
                            AetherSettingsRow(
                                label: server.name,
                                description: "Remove this server — its titles leave your library.",
                                systemImage: "minus.circle",
                                actionRole: .destructive
                            ) { onRemoveServer(server.id) }
                        }
                    }
                }

                if let onSwitchProfile {
                    AetherSettingsSection("Profile") {
                        if let activeProfileName {
                            AetherSettingsRow(label: "Watching as", value: activeProfileName)
                        }
                        AetherSettingsRow(
                            label: "Switch Profile",
                            description: "Choose a different Plex Home profile — each has its own watch history and libraries.",
                            systemImage: "person.2",
                            value: nil,
                            action: onSwitchProfile
                        )
                    }
                }

                if explainsActiveSource {
                    VStack(alignment: .leading, spacing: AetherDesign.Spacing.s) {
                        if canSetActive, let onSetActive {
                            AetherSettingsSection("Library") {
                                AetherSettingsRow(
                                    label: "Set as Active Source",
                                    description: "Browse this server in Library and Search.",
                                    actionRole: .primary,
                                    action: onSetActive
                                )
                            }
                        }
                        Text("Active only sets which server you browse in Library and Search. A title on more than one server always plays from your preferred copy — switch it on the title’s page.")
                            .font(AetherDesign.Typography.caption)
                            .foregroundStyle(AetherDesign.Palette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, AetherDesign.Spacing.m)
                    }
                }

                AetherSettingsSection("Account") {
                    AetherSettingsRow(
                        label: isSigningOut ? "Signing out…" : "Sign Out",
                        actionRole: .destructive
                    ) { confirmSignOut = true }
                    .disabled(isSigningOut)
                }
            }
            .padding(AetherDesign.Spacing.l)
            .frame(maxWidth: AetherSheetLayout.maxContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .tvOSScrollFocusable()
        }
        .confirmationDialog(
            "Sign out of \(title)?",
            isPresented: $confirmSignOut,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive, action: onSignOut)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can sign back in any time. Downloads and settings stay on this device.")
        }
        .aetherScreenBackground()
        .overlay(alignment: .topTrailing) {
            Button { dismiss(); onClose() } label: {
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
