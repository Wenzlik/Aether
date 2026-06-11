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
    @State private var folder = ""
    @State private var phase: Phase = .idle

    private enum Phase: Equatable {
        case idle, connecting, failed(String)
        var isConnecting: Bool { self == .connecting }
    }

    private var trimmedHost: String { host.trimmingCharacters(in: .whitespaces) }

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
                    TextField("Folder (optional, e.g. Media/Movies)", text: $folder)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
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
        }
    }

    private func connect() async {
        phase = .connecting
        let roots = folder.trimmingCharacters(in: .whitespaces).isEmpty
            ? []
            : [folder.trimmingCharacters(in: .whitespaces)]
        let connection = SMBConnection(
            host: trimmedHost,
            username: username.isEmpty ? nil : username,
            password: password.isEmpty ? nil : password,
            domain: domain.isEmpty ? nil : domain,
            roots: roots
        )

        // Validate by listing the chosen root (or the host root). Empty +
        // reachable is allowed (a share may simply hold no folders we surfaced);
        // we only fail when nothing comes back at all and creds look involved.
        let probeURL = roots.first.flatMap { connection.url(forPath: $0) } ?? connection.rootURL
        guard let probeURL else { phase = .failed("Invalid host."); return }
        let entries = await SMBBrowser.entries(at: probeURL, options: connection.vlcMediaOptions, timeoutMilliseconds: 6000)

        if entries.isEmpty {
            phase = .failed("Couldn't list anything at \(connection.host). Check the host, folder, credentials, and that Local Network access is allowed in Settings ▸ Privacy.")
            return
        }
        await session.completeSMBSignIn(connection: connection)
        dismiss()
    }
}
