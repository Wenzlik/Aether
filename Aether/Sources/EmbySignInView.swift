import SwiftUI
import AetherCore

/// Emby onboarding: type the server address, then approve a Quick Connect
/// code in the Emby dashboard. Presented from the sign-in sheet when the
/// user taps "Emby" in Settings → Sources.
struct EmbySignInView: View {
    @Bindable var session: AppSession
    @State private var viewModel: EmbySignInViewModel
    @State private var urlText: String = ""

    init(session: AppSession) {
        self.session = session
        _viewModel = State(initialValue: EmbySignInViewModel(authClient: session.embyAuthClient))
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
                Task { await session.completeEmbySignIn(record: record) }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            AetherWordmark(.small)
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
                Text("Connect Emby")
                    .font(AetherDesign.Typography.heroTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                Text("Enter your server address, then approve the code in Emby.")
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

            if let error {
                Text(error)
                    .font(AetherDesign.Typography.metadata)
                    .foregroundStyle(AetherDesign.Palette.error)
                    .fixedSize(horizontal: false, vertical: true)
            }

            AetherButton("Connect", systemImage: "arrow.right", role: .primary) {
                viewModel.connect(to: urlText)
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

            Text("In Emby, open your profile → Quick Connect (or Dashboard → Quick Connect) and enter this code.")
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
