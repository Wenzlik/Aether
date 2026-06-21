import SwiftUI
import AetherCore

/// Enable which Plex servers Aether uses — several from one account can be on at
/// once (#325), their content merged in the Unified Library. Loads the reachable
/// servers on appear (ranked best-first by `PlexServerSelector`) and toggles each
/// on/off in place.
///
/// The reachable set is network-dependent (a LAN server drops off when you leave
/// home), so this always re-fetches rather than trusting a stale list — what you
/// see is what's actually connectable right now.
struct PlexServerPickerSheet: View {
    /// Stable ids of the currently-enabled servers (seeds the toggles).
    let enabledIDs: Set<String>
    /// Fetches the reachable servers, ranked best-first. Returns `[]` on failure.
    let load: () async -> [PlexServerRecord]
    /// Enable / disable a server. The view mirrors the session's "keep ≥1
    /// enabled" rule so the last toggle can't be turned off.
    let onToggle: (PlexServerRecord, Bool) async -> Void
    /// Id of the current primary (first-enabled) server — gets the selected mark.
    var primaryServerID: String?
    /// Make a server the primary streaming source (#325 follow-up). Only enabled
    /// servers are offered.
    var onSetPrimary: (PlexServerRecord) async -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss

    private enum LoadState: Equatable {
        case loading
        case loaded([PlexServerRecord])
        case failed
    }
    @State private var state: LoadState = .loading
    /// Local, optimistic enabled set so toggles feel instant; seeded from
    /// `enabledIDs` once the list loads.
    @State private var enabled: Set<String> = []
    /// Local, optimistic primary id so the selection moves instantly; seeded
    /// from `primaryServerID`.
    @State private var primary: String?
    @State private var seeded = false
    /// A server mid-toggle, so its row shows progress and the list locks briefly.
    @State private var busy: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                Text("Plex Servers")
                    .font(AetherDesign.Typography.sectionTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)

                content
            }
            .padding(AetherDesign.Spacing.l)
            .frame(maxWidth: AetherSheetLayout.maxContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .aetherScreenBackground()
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
                    .padding(AetherDesign.Spacing.m)
            }
            .buttonStyle(.plain)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await refresh() }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            AetherLoadingState(.rails(count: 1))

        case .failed:
            AetherErrorState(
                title: "Couldn't load servers",
                message: "Aether couldn't reach Plex to list your servers. Check your connection and try again.",
                retry: .init(label: "Try again") { Task { await refresh() } }
            )

        case let .loaded(servers) where servers.isEmpty:
            AetherEmptyState(
                glyph: "server.rack",
                title: "No servers found",
                message: "Your Plex account isn't connected to any reachable servers right now."
            )

        case let .loaded(servers) where servers.count == 1:
            // Only one reachable server — nothing to combine, so just confirm it.
            AetherSettingsSection("Server") {
                AetherSettingsRow(label: servers[0].name, description: connectionDetail(servers[0]), value: "On")
            }
            Text("This is the only Plex server reachable on your account right now.")
                .font(AetherDesign.Typography.caption)
                .foregroundStyle(AetherDesign.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

        case let .loaded(servers):
            Text("Turn on the servers you want in your Library. Content from several servers on your account is merged into one collection.")
                .font(AetherDesign.Typography.caption)
                .foregroundStyle(AetherDesign.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            AetherSettingsSection("Reachable Servers") {
                ForEach(servers, id: \.clientIdentifier) { server in
                    let isOn = enabled.contains(server.clientIdentifier)
                    AetherSettingsRow(
                        label: server.name,
                        description: connectionDetail(server),
                        value: busy == server.clientIdentifier ? "…" : (isOn ? "On" : "Off")
                    ) {
                        Task { await toggle(server) }
                    }
                    .disabled(busy != nil)
                }
            }

            // Which enabled server streams first when a title is on more than one
            // (#325 follow-up). Radio-style so it works the same on Apple TV.
            let enabledServers = servers.filter { enabled.contains($0.clientIdentifier) }
            if enabledServers.count > 1 {
                AetherSettingsSection("Primary Server") {
                    ForEach(enabledServers, id: \.clientIdentifier) { server in
                        AetherSelectionRow(
                            title: server.name,
                            detail: connectionDetail(server),
                            isSelected: (primary ?? primaryServerID) == server.clientIdentifier
                        ) {
                            primary = server.clientIdentifier
                            Task { await onSetPrimary(server) }
                        }
                        .disabled(busy != nil)
                    }
                }
                Text("The primary server streams first when a title is on more than one of your servers.")
                    .font(AetherDesign.Typography.caption)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("To disconnect Plex entirely, use Sign Out.")
                .font(AetherDesign.Typography.caption)
                .foregroundStyle(AetherDesign.Palette.textTertiary)
        }
    }

    /// "On your network" / "Remote" / "Relay" — describes the best (first,
    /// already-ranked) connection so the user can tell a LAN server from a WAN one.
    private func connectionDetail(_ server: PlexServerRecord) -> String? {
        guard let best = server.connections.first else { return nil }
        if best.isLocal { return String(localized: "On your network") }
        if best.isRelay { return String(localized: "Relay") }
        return String(localized: "Remote")
    }

    private func refresh() async {
        state = .loading
        let servers = await load()
        // `load` maps failures to `[]`; an empty fetch is far more likely "no
        // servers reachable" than a hard error, so show the empty state.
        if !seeded {
            enabled = enabledIDs
            primary = primaryServerID
            seeded = true
        }
        state = .loaded(servers)
    }

    private func toggle(_ server: PlexServerRecord) async {
        let id = server.clientIdentifier
        let turnOn = !enabled.contains(id)
        // Mirror the session's "keep at least one enabled" rule — turning off the
        // last server is a no-op here (Sign Out is the way to disconnect).
        if !turnOn && enabled.count <= 1 { return }

        busy = id
        await onToggle(server, turnOn)
        if turnOn { enabled.insert(id) } else { enabled.remove(id) }
        busy = nil
    }
}
