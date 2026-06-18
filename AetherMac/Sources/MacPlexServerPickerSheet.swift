import SwiftUI
import AetherCore

/// macOS Settings sheet for managing Plex servers: enable / disable each
/// reachable server and pick which one streams first (#325 multi-server).
///
/// Mirrors the iOS `PlexServerPickerSheet` in behaviour — always re-fetches
/// reachable servers so LAN servers that dropped off don't appear falsely "on".
struct MacPlexServerPickerSheet: View {
    var session: MacSession
    @Environment(\.dismiss) private var dismiss

    private enum LoadState: Equatable {
        case loading
        case loaded([PlexServerRecord])
        case failed
    }
    @State private var state: LoadState = .loading
    /// Optimistic enabled set, seeded from `session.plexServerRecords` once loaded.
    @State private var enabled: Set<String> = []
    /// Optimistic primary id so the radio moves instantly.
    @State private var primary: String?
    /// The server whose toggle is mid-flight — disables the whole list briefly.
    @State private var busy: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Plex Servers")
                        .font(.title2.bold())
                    Text("Turn on the servers you want in your Library.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            Group {
                switch state {
                case .loading:
                    ProgressView("Connecting to Plex…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .failed:
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text("Couldn't reach Plex")
                            .font(.headline)
                        Text("Check your connection and try again.")
                            .foregroundStyle(.secondary)
                        Button("Try Again") { Task { await load() } }
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case let .loaded(servers) where servers.isEmpty:
                    VStack(spacing: 10) {
                        Image(systemName: "server.rack")
                            .font(.largeTitle)
                            .foregroundStyle(.quaternary)
                        Text("No servers found")
                            .font(.headline)
                        Text("Your Plex account isn't connected to any reachable servers right now.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()

                case let .loaded(servers):
                    Form {
                        Section("Reachable Servers") {
                            ForEach(servers, id: \.clientIdentifier) { server in
                                let isOn = enabled.contains(server.clientIdentifier)
                                Toggle(isOn: Binding(
                                    get: { isOn },
                                    set: { _ in Task { await toggle(server) } }
                                )) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(server.name)
                                        if let detail = connectionDetail(server) {
                                            Text(detail)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .disabled(busy != nil || (isOn && enabled.count == 1))
                            }
                        }

                        let enabledServers = servers.filter { enabled.contains($0.clientIdentifier) }
                        if enabledServers.count > 1 {
                            Section {
                                Picker("Primary Server", selection: Binding(
                                    get: { primary ?? session.primaryPlexServerID ?? "" },
                                    set: { id in
                                        if let record = servers.first(where: { $0.clientIdentifier == id }) {
                                            primary = id
                                            Task { await session.setPrimaryPlexServer(record) }
                                        }
                                    }
                                )) {
                                    ForEach(enabledServers, id: \.clientIdentifier) { server in
                                        Text(server.name).tag(server.clientIdentifier)
                                    }
                                }
                                Text("The primary server streams first when a title is on more than one of your servers.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Section {
                            Text("Content from enabled servers is merged into one Library. To disconnect Plex entirely, use Sign Out in the Accounts tab.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .formStyle(.grouped)
                    .disabled(busy != nil)
                }
            }
        }
        .frame(width: 420, height: 480)
        .task { await load() }
    }

    private func load() async {
        state = .loading
        enabled = Set(session.plexServerRecords.map(\.clientIdentifier))
        primary = session.primaryPlexServerID
        guard let servers = await session.loadReachablePlexServers() else {
            state = .failed
            return
        }
        state = .loaded(servers)
    }

    private func toggle(_ server: PlexServerRecord) async {
        let id = server.clientIdentifier
        let turnOn = !enabled.contains(id)
        // Mirror the "keep ≥1 enabled" rule in MacSession.
        if !turnOn && enabled.count <= 1 { return }
        busy = id
        await session.setPlexServerEnabled(server, enabled: turnOn)
        if turnOn { enabled.insert(id) } else { enabled.remove(id) }
        busy = nil
    }

    private func connectionDetail(_ server: PlexServerRecord) -> String? {
        guard let best = server.connections.first else { return nil }
        if best.isLocal { return "On your network" }
        if best.isRelay { return "Relay" }
        return "Remote"
    }
}
