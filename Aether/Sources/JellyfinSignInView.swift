import SwiftUI
import AetherCore

/// Jellyfin onboarding: type the server address, then approve a Quick Connect
/// code in the Jellyfin dashboard. Presented from the sign-in sheet when the
/// user taps "Jellyfin" in Settings → Sources.
struct JellyfinSignInView: View {
    /// Which Jellyfin sign-in flow the user picked.
    private enum SignInMethod: Hashable {
        case quickConnect
        case password
    }

    @Bindable var session: AppSession
    @State private var viewModel: JellyfinSignInViewModel
    @State private var urlText: String = ""
    @State private var method: SignInMethod = .quickConnect
    @State private var username: String = ""
    @State private var password: String = ""

    init(session: AppSession) {
        self.session = session
        _viewModel = State(initialValue: JellyfinSignInViewModel(authClient: session.jellyfinAuthClient))
    }

    var body: some View {
        ZStack {
            AetherDesign.Gradients.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                header
                content
                Spacer(minLength: 0)
                cancelButton
            }
            .padding(AetherDesign.Spacing.xxl)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onChange(of: viewModel.state) { _, newValue in
            if case let .success(record) = newValue {
                Task { await session.completeJellyfinSignIn(record: record) }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            AetherWordmark(.small)
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
                Text("Connect Jellyfin")
                    .font(AetherDesign.Typography.heroTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                Text("Enter your server address, then sign in with Quick Connect or your username and password.")
                    .font(AetherDesign.Typography.metadata)
                    .foregroundStyle(AetherDesign.Palette.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .enterURL:
            urlEntry(error: nil)
        case let .failed(message):
            urlEntry(error: message)
        case .validating:
            HStack(spacing: AetherDesign.Spacing.s) {
                ProgressView().tint(AetherDesign.Palette.textSecondary)
                Text("Checking server…")
                    .font(AetherDesign.Typography.body)
                    .foregroundStyle(AetherDesign.Palette.textSecondary)
            }
        case let .awaitingApproval(code):
            approval(code: code)
        case .success:
            HStack(spacing: AetherDesign.Spacing.s) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AetherDesign.Palette.success)
                Text("Connected")
                    .font(AetherDesign.Typography.sectionTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
            }
        }
    }

    private func urlEntry(error: String?) -> some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            Text("Server address")
                .font(AetherDesign.Typography.caption)
                .foregroundStyle(AetherDesign.Palette.textTertiary)

            TextField("http://192.168.1.10:8096", text: $urlText)
                .textContentType(.URL)
                .autocorrectionDisabled()
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .font(AetherDesign.Typography.body)
                .padding(AetherDesign.Spacing.m)
                .background(AetherDesign.Palette.surface, in: RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous))
                .foregroundStyle(AetherDesign.Palette.textPrimary)

            Picker("Sign-in method", selection: $method) {
                Text("Quick Connect").tag(SignInMethod.quickConnect)
                Text("Username & password").tag(SignInMethod.password)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if method == .password {
                credentialFields
            }

            if let error {
                Text(error)
                    .font(AetherDesign.Typography.metadata)
                    .foregroundStyle(AetherDesign.Palette.error)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch method {
            case .quickConnect:
                AetherButton("Connect", systemImage: "arrow.right", role: .primary) {
                    viewModel.connect(to: urlText)
                }
            case .password:
                AetherButton("Sign In", systemImage: "arrow.right", role: .primary) {
                    viewModel.signInWithPassword(to: urlText, username: username, password: password)
                }
            }
        }
    }

    private var credentialFields: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            TextField("Username", text: $username)
                .textContentType(.username)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .font(AetherDesign.Typography.body)
                .padding(AetherDesign.Spacing.m)
                .background(AetherDesign.Palette.surface, in: RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous))
                .foregroundStyle(AetherDesign.Palette.textPrimary)

            SecureField("Password", text: $password)
                .textContentType(.password)
                .font(AetherDesign.Typography.body)
                .padding(AetherDesign.Spacing.m)
                .background(AetherDesign.Palette.surface, in: RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous))
                .foregroundStyle(AetherDesign.Palette.textPrimary)
                .onSubmit {
                    viewModel.signInWithPassword(to: urlText, username: username, password: password)
                }
        }
    }

    private func approval(code: String) -> some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
                Text("Your code")
                    .font(AetherDesign.Typography.caption)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
                Text(code)
                    .font(.system(size: 56, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .kerning(8)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
            }

            Text("In Jellyfin, open your profile → Quick Connect (or Dashboard → Quick Connect) and enter this code.")
                .font(AetherDesign.Typography.body)
                .foregroundStyle(AetherDesign.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: AetherDesign.Spacing.s) {
                ProgressView().tint(AetherDesign.Palette.textSecondary)
                Text("Waiting for you to approve the code…")
                    .font(AetherDesign.Typography.metadata)
                    .foregroundStyle(AetherDesign.Palette.textSecondary)
            }
        }
    }

    private var cancelButton: some View {
        AetherButton("Cancel", role: .secondary) {
            viewModel.reset()
            session.isSignInPresented = false
        }
    }
}
