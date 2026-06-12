import SwiftUI
import AetherCore

/// Add-by-host SMB sign-in (#214). Enter the NAS host + optional credentials,
/// validate by listing the host root over SMB, then hand a `SMBConnection` to
/// `AppSession.completeSMBSignIn`. No share picker in v1 — leaving the folder
/// blank scans every share found at the host.
struct SMBConnectView: View {
    @Bindable var session: AppSession
    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var username = ""
    @State private var password = ""
    @State private var domain = ""
    @State private var selectedRoots: [String] = []
    @State private var showFolderPicker = false
    @State private var isPreparingBrowse = false
    @State private var phase: Phase = .idle

    private enum Phase: Equatable {
        case idle, connecting, failed(String)
        var isConnecting: Bool { self == .connecting }
    }

    private var trimmedHost: String { host.trimmingCharacters(in: .whitespaces) }

    /// A connection built from the current form, for the folder picker to browse.
    private var draftConnection: SMBConnection {
        SMBConnection(
            host: trimmedHost,
            username: username.isEmpty ? nil : username,
            password: password.isEmpty ? nil : password,
            domain: domain.isEmpty ? nil : domain,
            roots: selectedRoots
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Host or IP (e.g. 192.168.1.10)", text: $host)
                        .textContentType(.URL)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .autocorrectionDisabled()
                }
                Section("Credentials (leave blank for a guest share)") {
                    TextField("Username", text: $username)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    SecureField("Password", text: $password)
                    TextField("Domain / Workgroup (optional)", text: $domain)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }
                Section("Folders") {
                    if selectedRoots.isEmpty {
                        Text("All shares will be scanned. Browse to pick specific folders instead.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(selectedRoots, id: \.self) { root in
                            Label(root, systemImage: "folder.fill")
                        }
                        .onDelete { selectedRoots.remove(atOffsets: $0) }
                    }
                    if isPreparingBrowse {
                        HStack { ProgressView(); Text("Connecting…").foregroundStyle(.secondary) }
                    } else {
                        Button {
                            Task { await prepareBrowse() }
                        } label: {
                            Label(selectedRoots.isEmpty ? "Browse Folders…" : "Add More Folders…", systemImage: "folder.badge.plus")
                        }
                        .disabled(trimmedHost.isEmpty)
                    }
                }
                if case let .failed(message) = phase {
                    Section { Text(message).foregroundStyle(.red) }
                }
                Section {
                    Text("On first connect iOS will ask for Local Network access — allow it, or the share can't be reached.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Connect SMB")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if phase.isConnecting {
                        ProgressView()
                    } else {
                        Button("Connect") { Task { await connect() } }
                            .disabled(trimmedHost.isEmpty)
                    }
                }
            }
            .sheet(isPresented: $showFolderPicker) {
                SMBFolderPickerView(connection: draftConnection, selectedRoots: $selectedRoots)
            }
        }
    }

    /// Trigger the Local Network prompt + confirm reachability before opening the
    /// folder picker (the picker's first SMB call would otherwise be silently
    /// blocked on a fresh install — same reason `connect()` probes first).
    private func prepareBrowse() async {
        isPreparingBrowse = true
        defer { isPreparingBrowse = false }
        phase = .idle
        if await SMBNetworkProbe.probe(host: trimmedHost) == .blocked {
            phase = .failed("Couldn't reach \(trimmedHost) on your network. Allow Local Network access (Settings ▸ Privacy & Security ▸ Local Network ▸ Aether) and check the IP is correct.")
            return
        }
        showFolderPicker = true
    }

    private func connect() async {
        phase = .connecting
        let roots = selectedRoots
        let connection = SMBConnection(
            host: trimmedHost,
            username: username.isEmpty ? nil : username,
            password: password.isEmpty ? nil : password,
            domain: domain.isEmpty ? nil : domain,
            roots: roots
        )

        // Trigger the iOS Local Network prompt + confirm the host is reachable
        // BEFORE the libsmb2 browse: libVLC's raw sockets don't make iOS show
        // the prompt, so without this the connection is silently blocked and the
        // app never even appears in Settings ▸ Privacy ▸ Local Network (#214).
        // An NWConnection does trigger it; the grant then applies app-wide.
        if await SMBNetworkProbe.probe(host: trimmedHost) == .blocked {
            phase = .failed("Couldn't reach \(trimmedHost) on your network. If iOS asked for Local Network access, allow it; if it didn't, enable it in Settings ▸ Privacy & Security ▸ Local Network ▸ Aether. Also check the IP is correct and on the same Wi-Fi.")
            return
        }

        // Validate via the native SMB client (AMSMB2) — it throws the *real*
        // SMB error (bad credentials, no such share, host down), so we can show
        // the actual reason instead of guessing from an empty VLC listing (#213).
        let client = SMBSession(connection: connection)
        do {
            if let firstRoot = roots.first {
                // A specific folder/share was given: connect + list it (throws on
                // bad share / auth).
                let (share, path) = SMBConnection.splitShareAndPath(firstRoot)
                _ = try await client.list(share: share, path: path)
            } else {
                // No folder: enumerate the server's shares.
                let shares = try await client.shares()
                guard !shares.isEmpty else {
                    phase = .failed("Connected to \(connection.host) but it has no shares we can read. Enter a specific Folder (e.g. \"Media\").")
                    return
                }
            }
            await session.completeSMBSignIn(connection: connection)
            dismiss()
        } catch {
            phase = .failed("Couldn't connect to \(connection.host).\n\n\(error.localizedDescription)\n\nCheck the username, password, domain, and — if you set a Folder — that the share exists.")
        }
    }
}
