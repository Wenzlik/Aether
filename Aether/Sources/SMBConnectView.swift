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

        // Trigger the iOS Local Network prompt + confirm the host is reachable
        // BEFORE the libsmb2 browse: libVLC's raw sockets don't make iOS show
        // the prompt, so without this the connection is silently blocked and the
        // app never even appears in Settings ▸ Privacy ▸ Local Network (#214).
        // An NWConnection does trigger it; the grant then applies app-wide.
        if await SMBNetworkProbe.probe(host: trimmedHost) == .blocked {
            phase = .failed("Couldn't reach \(trimmedHost) on your network. If iOS asked for Local Network access, allow it; if it didn't, enable it in Settings ▸ Privacy & Security ▸ Local Network ▸ Aether. Also check the IP is correct and on the same Wi-Fi.")
            return
        }

        // Validate by listing the chosen root (or the host root). Use the rich
        // browse so we can say *why* it came back empty rather than one generic
        // failure — the status (timeout / failed / done-but-empty) maps to very
        // different fixes.
        let probeURL = roots.first.flatMap { connection.url(forPath: $0) } ?? connection.rootURL
        guard let probeURL else { phase = .failed("Invalid host."); return }
        let result = await SMBBrowser.browse(at: probeURL, options: connection.vlcMediaOptions, timeoutMilliseconds: 6000)

        if !result.isEmpty {
            await session.completeSMBSignIn(connection: connection)
            dismiss()
            return
        }

        // libsmb2's own last error line, when it logged one — the most precise
        // hint (e.g. STATUS_LOGON_FAILURE = creds, STATUS_BAD_NETWORK_NAME = share).
        let detail = result.diagnostic.map { "\n\nServer said: \($0)" } ?? ""
        let scanningWholeHost = roots.isEmpty
        switch result.status {
        case .timeout, .notStarted:
            phase = .failed("Couldn't reach \(connection.host). Check the host/IP is correct and reachable, and that Local Network access is allowed for Aether (Settings ▸ Privacy ▸ Local Network on iOS). On the Simulator, Local Network access is unreliable — try a real device.\(detail)")
        case .failed:
            phase = .failed("\(connection.host) refused the request. Check the username, password and domain — and, if you set a Folder, that the path exists.\(detail)")
        case .done where scanningWholeHost:
            // Reached the host, but listing *shares* at smb://host/ returned
            // nothing. Many NAS block anonymous share enumeration — the practical
            // fix is to name a specific share instead of scanning the whole host.
            phase = .failed("Reached \(connection.host) but couldn't list any shares — many NAS block browsing the whole server. Enter a specific Folder (e.g. Media or Movies) and try again.\(detail)")
        case .done:
            phase = .failed("Reached the folder on \(connection.host) but it held nothing we could list. Double-check the Folder path (it's relative to the server root, e.g. Media/Movies).\(detail)")
        }
    }
}
