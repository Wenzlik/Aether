import SwiftUI
import AetherCore

/// Add an SMB share — enter the server, share name and (optionally) credentials.
/// On Connect the session mounts the share via NetFS to validate it before
/// saving; success dismisses, failure shows why. Mirrors the chrome of the
/// Plex/Jellyfin sign-in sheets.
struct SMBAddShareSheet: View {
    let session: MacSession
    let onDone: () -> Void

    @State private var host = ""
    @State private var shareName = ""
    @State private var username = ""
    @State private var password = ""
    @State private var step: Step = .entry

    private enum Step: Equatable {
        case entry
        case connecting
        case failed(String)
    }

    private var canConnect: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !shareName.trimmingCharacters(in: CharacterSet(charactersIn: " /")).isEmpty
            && step != .connecting
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Add SMB Share").font(.title2.bold())
            content
            Button("Cancel") { onDone() }
                .keyboardShortcut(.cancelAction)
                .disabled(step == .connecting)
        }
        .padding(40)
        .frame(width: 440)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .entry, .failed:
            VStack(alignment: .leading, spacing: 12) {
                TextField("Server (e.g. nas.local or 192.168.1.10)", text: $host)
                    .textFieldStyle(.roundedBorder)
                TextField("Share name (e.g. Media)", text: $shareName)
                    .textFieldStyle(.roundedBorder)
                TextField("Username (optional)", text: $username)
                    .textFieldStyle(.roundedBorder)
                SecureField("Password (optional)", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if canConnect { connect() } }

                if case let .failed(message) = step {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button("Connect") { connect() }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConnect)
                    .frame(maxWidth: .infinity, alignment: .center)

                Text("Leave the username and password empty to connect as a guest. The share is mounted on this Mac and scanned for movies and shows.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 340)
        case .connecting:
            ProgressView("Connecting to the share…")
        }
    }

    private func connect() {
        step = .connecting
        Task {
            let error = await session.addSMBShare(
                host: host,
                shareName: shareName,
                username: username.isEmpty ? nil : username,
                password: password.isEmpty ? nil : password
            )
            if let error {
                step = .failed(error)
            } else {
                onDone()
            }
        }
    }
}
