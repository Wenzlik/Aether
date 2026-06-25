import SwiftUI
import AetherCore

/// Plex sign-in — reuses AetherCore's `PlexSignInViewModel` (the PIN/link flow),
/// just renders its `state`.
struct PlexSignInSheet: View {
    let session: MacSession
    let onDone: () -> Void
    @State private var vm: PlexSignInViewModel
    @Environment(\.openURL) private var openURL

    init(session: MacSession, onDone: @escaping () -> Void) {
        self.session = session
        self.onDone = onDone
        _vm = State(initialValue: PlexSignInViewModel(
            authClient: session.plexAuthClient, homeClient: session.plexHomeClient))
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Connect Plex").font(.title2.bold())
            content
            Button("Cancel") { vm.cancel(); onDone() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(40)
        .frame(width: 440)
        .task { vm.start() }
        .onChange(of: vm.state) { _, state in
            if case let .success(result) = state {
                Task { await session.completePlexSignIn(result: result); onDone() }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.state {
        case .idle, .requesting:
            ProgressView("Requesting a code…")
        case let .awaitingUser(pin, linkURL):
            VStack(spacing: 14) {
                Text("Enter this code at plex.tv/link:").foregroundStyle(.secondary)
                Text(pin.code)
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .textSelection(.enabled)
                Button("Open plex.tv/link") { openURL(linkURL) }
                    .controlSize(.large)
                ProgressView().controlSize(.small)
                Text("Waiting for you to authorize…").font(.caption).foregroundStyle(.secondary)
            }
        case let .selectingProfile(users):
            MacPlexProfilePicker(
                users: users,
                isSwitching: vm.isSwitching,
                pinError: vm.pinError,
                onChoose: { user, pin in vm.chooseProfile(user, pin: pin) }
            )
        case .success:
            ProgressView("Connecting…")
        case let .failure(reason):
            VStack(spacing: 12) {
                Label("Couldn't connect", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(String(describing: reason)).font(.caption).foregroundStyle(.secondary)
                Button("Try Again") { vm.retry() }
            }
        }
    }
}

/// Plex Home profile chooser, macOS-native (used in sign-in and the Settings
/// switcher). Self-contained PIN handling: a protected profile reveals a PIN
/// field; others switch immediately. The owner performs the switch via
/// `onChoose` and feeds back `isSwitching` / `pinError`.
struct MacPlexProfilePicker: View {
    let users: [PlexAPI.HomeUser]
    let isSwitching: Bool
    let pinError: Bool
    let onChoose: (PlexAPI.HomeUser, String?) -> Void

    @State private var pinUser: PlexAPI.HomeUser?
    @State private var pin = ""

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 20)]

    var body: some View {
        if let pinUser {
            pinEntry(for: pinUser)
        } else {
            VStack(spacing: 16) {
                Text("Who's watching?").font(.headline)
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(users) { user in
                        Button {
                            if user.isProtected { pin = ""; pinUser = user }
                            else { onChoose(user, nil) }
                        } label: {
                            VStack(spacing: 8) {
                                avatar(for: user)
                                Text(user.title).font(.callout).lineLimit(1)
                                if user.isProtected {
                                    Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isSwitching)
                    }
                }
            }
        }
    }

    private func pinEntry(for user: PlexAPI.HomeUser) -> some View {
        VStack(spacing: 14) {
            avatar(for: user)
            Text(user.title).font(.headline)
            Text("Enter this profile's PIN").font(.caption).foregroundStyle(.secondary)
            SecureField("PIN", text: $pin)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
                .multilineTextAlignment(.center)
                .onSubmit { submit(user) }
            if pinError {
                Text("Wrong PIN. Try again.").font(.caption).foregroundStyle(.red)
            }
            HStack(spacing: 12) {
                Button("Back") { pinUser = nil; pin = "" }
                Button("Continue") { submit(user) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(pin.isEmpty || isSwitching)
            }
            if isSwitching { ProgressView().controlSize(.small) }
        }
    }

    private func avatar(for user: PlexAPI.HomeUser) -> some View {
        ZStack {
            Circle().fill(Color.accentColor.opacity(0.18))
            if let thumb = user.thumb, let url = URL(string: thumb) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Text(String(user.title.prefix(1)).uppercased()).font(.title.bold())
                }
                .clipShape(Circle())
            } else {
                Text(String(user.title.prefix(1)).uppercased()).font(.title.bold())
            }
        }
        .frame(width: 80, height: 80)
    }

    private func submit(_ user: PlexAPI.HomeUser) {
        guard !pin.isEmpty, !isSwitching else { return }
        onChoose(user, pin)
    }
}

/// Settings sheet that swaps the active Plex Home profile at runtime (macOS).
struct MacPlexProfileSwitchSheet: View {
    let session: MacSession
    let onDone: () -> Void

    @State private var users: [PlexAPI.HomeUser] = []
    @State private var loading = true
    @State private var isSwitching = false
    @State private var pinError = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Switch Profile").font(.title2.bold())
            if loading {
                ProgressView()
            } else if users.count <= 1 {
                Text("No other profiles on this account.").foregroundStyle(.secondary)
            } else {
                MacPlexProfilePicker(
                    users: users,
                    isSwitching: isSwitching,
                    pinError: pinError,
                    onChoose: choose
                )
            }
            Button("Done") { onDone() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(40)
        .frame(width: 460)
        .task {
            users = await session.plexHomeUsers()
            loading = false
        }
    }

    private func choose(_ user: PlexAPI.HomeUser, _ pin: String?) {
        isSwitching = true
        pinError = false
        Task {
            do {
                try await session.switchPlexUser(user, pin: pin)
                isSwitching = false
                onDone()
            } catch PlexHomeError.invalidPIN {
                isSwitching = false
                pinError = true
            } catch {
                isSwitching = false
                onDone()
            }
        }
    }
}

/// Jellyfin sign-in via **Quick Connect** — enter the server URL, then approve
/// the shown code in Jellyfin (Dashboard ▸ Quick Connect / on another signed-in
/// client). Mirrors the iOS flow, driven directly off `JellyfinAuthClient`.
struct JellyfinSignInSheet: View {
    let session: MacSession
    let onDone: () -> Void
    @State private var model: JellyfinQuickConnectModel

    init(session: MacSession, onDone: @escaping () -> Void) {
        self.session = session
        self.onDone = onDone
        _model = State(initialValue: JellyfinQuickConnectModel(auth: session.jellyfinAuthClient))
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Connect Jellyfin").font(.title2.bold())
            content
            Button("Cancel") { onDone() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(40)
        .frame(width: 440)
        .onChange(of: model.record) { _, record in
            if let record {
                Task { await session.completeJellyfinSignIn(record); onDone() }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .enterURL:
            VStack(spacing: 12) {
                TextField("https://jellyfin.example.com", text: $model.urlString)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 320)

                Picker("Sign-in method", selection: $model.method) {
                    Text("Quick Connect").tag(JellyfinQuickConnectModel.Method.quickConnect)
                    Text("Username & password").tag(JellyfinQuickConnectModel.Method.password)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 320)

                if model.method == .password {
                    TextField("Username", text: $model.username)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 320)
                    SecureField("Password", text: $model.password)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 320)
                        .onSubmit { model.signInWithPassword() }
                }

                switch model.method {
                case .quickConnect:
                    Button("Connect") { model.connect() }
                        .controlSize(.large)
                        .disabled(model.urlString.trimmingCharacters(in: .whitespaces).isEmpty)
                case .password:
                    Button("Sign In") { model.signInWithPassword() }
                        .controlSize(.large)
                        .disabled(
                            model.urlString.trimmingCharacters(in: .whitespaces).isEmpty
                            || model.username.trimmingCharacters(in: .whitespaces).isEmpty
                        )
                }
            }
        case .connecting:
            ProgressView("Contacting server…")
        case let .awaiting(code):
            VStack(spacing: 14) {
                Text("Approve this code in Jellyfin\n(Dashboard ▸ Quick Connect, or a signed-in client):")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Text(code)
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .textSelection(.enabled)
                ProgressView().controlSize(.small)
            }
        case let .failed(message):
            VStack(spacing: 12) {
                Label("Couldn't connect", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(message).font(.caption).foregroundStyle(.secondary)
                Button("Try Again") { model.step = .enterURL }
            }
        }
    }
}

/// Emby sign-in via **Quick Connect** — mirrors `JellyfinSignInSheet`.
struct EmbySignInSheet: View {
    let session: MacSession
    let onDone: () -> Void
    @State private var model: EmbyQuickConnectModel

    init(session: MacSession, onDone: @escaping () -> Void) {
        self.session = session
        self.onDone = onDone
        _model = State(initialValue: EmbyQuickConnectModel(auth: session.embyAuthClient))
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Connect Emby").font(.title2.bold())
            content
            Button("Cancel") { onDone() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(40)
        .frame(width: 440)
        .onChange(of: model.record) { _, record in
            if let record {
                Task { await session.completeEmbySignIn(record); onDone() }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .enterURL:
            VStack(spacing: 12) {
                TextField("http://192.168.1.10:8096", text: $model.urlString)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 320)
                Button("Connect") { model.connect() }
                    .controlSize(.large)
                    .disabled(model.urlString.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        case .connecting:
            ProgressView("Contacting server…")
        case let .awaiting(code):
            VStack(spacing: 14) {
                Text("Approve this code in Emby\n(Dashboard ▸ Quick Connect, or a signed-in client):")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Text(code)
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .textSelection(.enabled)
                ProgressView().controlSize(.small)
            }
        case let .failed(message):
            VStack(spacing: 12) {
                Label("Couldn't connect", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(message).font(.caption).foregroundStyle(.secondary)
                Button("Try Again") { model.step = .enterURL }
            }
        }
    }
}

/// Drives the Emby Quick Connect handshake against `EmbyAuthClient`.
@MainActor
@Observable
final class EmbyQuickConnectModel {
    enum Step: Equatable {
        case enterURL
        case connecting
        case awaiting(code: String)
        case failed(String)
    }

    var urlString = ""
    var step: Step = .enterURL
    var record: EmbyServerRecord?

    private let auth: EmbyAuthClient

    init(auth: EmbyAuthClient) { self.auth = auth }

    func connect() {
        let raw = urlString.trimmingCharacters(in: .whitespaces)
        let normalized = raw.contains("://") ? raw : "http://\(raw)"
        guard let baseURL = URL(string: normalized) else { step = .failed("Invalid URL"); return }
        step = .connecting
        Task {
            do {
                let info = try await auth.publicInfo(baseURL: baseURL)
                let qc = try await auth.initiateQuickConnect(baseURL: baseURL)
                step = .awaiting(code: qc.code)
                let result = try await auth.pollForAuthentication(baseURL: baseURL, secret: qc.secret)
                record = EmbyServerRecord(
                    baseURLString: baseURL.absoluteString,
                    accessToken: result.accessToken,
                    userID: result.user.id,
                    serverName: info.serverName ?? baseURL.host ?? "Emby"
                )
            } catch EmbyAuthError.notEnabled {
                step = .failed("Quick Connect isn't enabled on this server. Enable it in Emby ▸ Dashboard ▸ Quick Connect.")
            } catch {
                step = .failed(error.localizedDescription)
            }
        }
    }
}

/// Drives the Jellyfin Quick Connect handshake against `JellyfinAuthClient`.
@MainActor
@Observable
final class JellyfinQuickConnectModel {
    enum Step: Equatable {
        case enterURL
        case connecting
        case awaiting(code: String)
        case failed(String)
    }

    /// Which sign-in flow the user picked.
    enum Method: Hashable { case quickConnect, password }

    var urlString = ""
    var step: Step = .enterURL
    var method: Method = .quickConnect
    var username = ""
    var password = ""
    /// Set once authenticated — the view watches it to finish + persist.
    var record: JellyfinServerRecord?

    private let auth: JellyfinAuthClient

    init(auth: JellyfinAuthClient) { self.auth = auth }

    func connect() {
        let raw = urlString.trimmingCharacters(in: .whitespaces)
        let normalized = raw.contains("://") ? raw : "http://\(raw)"
        guard let baseURL = URL(string: normalized) else { step = .failed("Invalid URL"); return }
        step = .connecting
        Task {
            do {
                let info = try await auth.publicInfo(baseURL: baseURL)
                guard try await auth.quickConnectEnabled(baseURL: baseURL) else {
                    step = .failed("Quick Connect isn't enabled on this server. Enable it in Jellyfin ▸ Dashboard ▸ Quick Connect.")
                    return
                }
                let qc = try await auth.initiateQuickConnect(baseURL: baseURL)
                step = .awaiting(code: qc.code)
                let result = try await auth.pollForAuthentication(baseURL: baseURL, secret: qc.secret)
                record = JellyfinServerRecord(
                    baseURLString: baseURL.absoluteString,
                    accessToken: result.accessToken,
                    userID: result.user.id,
                    serverName: info.serverName ?? baseURL.host ?? "Jellyfin"
                )
            } catch {
                step = .failed(error.localizedDescription)
            }
        }
    }

    /// Sign in with a username and password (`/Users/AuthenticateByName`) — the
    /// alternative to Quick Connect, no code to approve.
    func signInWithPassword() {
        let raw = urlString.trimmingCharacters(in: .whitespaces)
        let normalized = raw.contains("://") ? raw : "http://\(raw)"
        guard let baseURL = URL(string: normalized) else { step = .failed("Invalid URL"); return }
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty else { step = .failed("Enter your Jellyfin username."); return }
        step = .connecting
        Task {
            do {
                let info = try await auth.publicInfo(baseURL: baseURL)
                let result = try await auth.authenticateByName(baseURL: baseURL, username: user, password: password)
                record = JellyfinServerRecord(
                    baseURLString: baseURL.absoluteString,
                    accessToken: result.accessToken,
                    userID: result.user.id,
                    serverName: info.serverName ?? baseURL.host ?? "Jellyfin"
                )
            } catch JellyfinAuthError.invalidCredentials {
                step = .failed("Wrong username or password. Check your details and try again.")
            } catch {
                step = .failed(error.localizedDescription)
            }
        }
    }
}
