import SwiftUI
import AetherCore

/// Choose which Plex server Aether uses when the account can reach more than
/// one (#323). Loads the reachable servers on appear (ranked best-first by
/// `PlexServerSelector`), marks the current one, and switches on tap.
///
/// The reachable set is network-dependent (a LAN server drops off when you
/// leave home), so this always re-fetches rather than trusting a stale list —
/// what you see is what's actually connectable right now.
struct PlexServerPickerSheet: View {
    /// Stable id of the server in use, to mark the checked row.
    let currentServerID: String?
    /// Fetches the reachable servers, ranked best-first. Returns `[]` on failure.
    let load: () async -> [PlexServerRecord]
    /// Switch to the chosen server.
    let onSelect: (PlexServerRecord) async -> Void

    @Environment(\.dismiss) private var dismiss

    private enum LoadState: Equatable {
        case loading
        case loaded([PlexServerRecord])
        case failed
    }
    @State private var state: LoadState = .loading
    /// The server being switched to, so its row shows progress and the list
    /// disables while the source rebuilds.
    @State private var switchingTo: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                Text("Choose Server")
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
            // Nothing to switch to — be honest rather than offer a one-item picker.
            AetherSettingsSection("Server") {
                AetherSettingsRow(label: servers[0].name, value: "In use")
            }
            Text("This is the only Plex server reachable on your account right now.")
                .font(AetherDesign.Typography.caption)
                .foregroundStyle(AetherDesign.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

        case let .loaded(servers):
            Text("Pick which server to browse. Aether ranks them by connection quality — the one on your network is preferred.")
                .font(AetherDesign.Typography.caption)
                .foregroundStyle(AetherDesign.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            AetherSettingsSection("Reachable Servers") {
                ForEach(servers, id: \.clientIdentifier) { server in
                    AetherSelectionRow(
                        title: server.name,
                        detail: switchingTo == server.clientIdentifier ? "Switching…" : connectionDetail(server),
                        isSelected: server.clientIdentifier == currentServerID
                    ) {
                        Task { await select(server) }
                    }
                    .disabled(switchingTo != nil)
                }
            }
        }
    }

    /// "On your network" / "Remote" / "Relay" — describes the best (first,
    /// already-ranked) connection so the user can tell a LAN server from a WAN one.
    private func connectionDetail(_ server: PlexServerRecord) -> String? {
        guard let best = server.connections.first else { return nil }
        if best.isLocal { return "On your network" }
        if best.isRelay { return "Relay" }
        return "Remote"
    }

    private func refresh() async {
        state = .loading
        let servers = await load()
        // `load` maps failures to `[]`; we can't tell "empty" from "errored", so
        // treat a nil-ish result conservatively — but an empty fetch is far more
        // likely "no servers" than a hard failure, so show the empty state.
        state = .loaded(servers)
    }

    private func select(_ server: PlexServerRecord) async {
        guard server.clientIdentifier != currentServerID else { dismiss(); return }
        switchingTo = server.clientIdentifier
        await onSelect(server)
        switchingTo = nil
        dismiss()
    }
}
