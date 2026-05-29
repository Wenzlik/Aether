import SwiftUI
import AetherCore

/// The Plex PIN sign-in surface.
///
/// Same view on iOS and tvOS — the platform difference is only in *how* the
/// user follows the link: iOS opens `plex.tv/link` directly via `\.openURL`;
/// tvOS shows a QR code the user scans with a phone (tvOS has no browser).
/// The QR code is also shown on iOS — it doesn't hurt and lets users hand
/// off the flow to another device if they want.
struct PlexSignInView: View {
    @State private var viewModel: PlexSignInViewModel
    let onSuccess: (String) -> Void
    let onCancel: () -> Void

    @Environment(\.openURL) private var openURL

    init(
        authClient: PlexAuthClient,
        onSuccess: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self._viewModel = State(initialValue: PlexSignInViewModel(authClient: authClient))
        self.onSuccess = onSuccess
        self.onCancel = onCancel
    }

    var body: some View {
        ZStack {
            AetherDesign.Palette.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                header

                Spacer(minLength: 0)

                stateContent

                Spacer(minLength: 0)

                cancelButton
            }
            .frame(maxWidth: 720, maxHeight: .infinity, alignment: .topLeading)
            .padding(AetherDesign.Spacing.xl)
        }
        .task {
            if case .idle = viewModel.state {
                viewModel.start()
            }
        }
        .onChange(of: stateIsSuccess) { _, isSuccess in
            if isSuccess, case let .success(token) = viewModel.state {
                onSuccess(token)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
            Text("Connect to Plex")
                .font(AetherDesign.Typography.heroTitle)
                .foregroundStyle(AetherDesign.Palette.textPrimary)
            Text("Sign in by entering a four-letter code on plex.tv/link.")
                .font(AetherDesign.Typography.metadata)
                .foregroundStyle(AetherDesign.Palette.textSecondary)
        }
    }

    // MARK: - State-dependent content

    @ViewBuilder
    private var stateContent: some View {
        switch viewModel.state {
        case .idle, .requesting:
            requestingView

        case let .awaitingUser(pin, url):
            awaitingUserView(pin: pin, url: url)

        case .success:
            successView

        case let .failure(reason):
            failureView(reason: reason)
        }
    }

    private var requestingView: some View {
        HStack(spacing: AetherDesign.Spacing.s) {
            ProgressView()
                .tint(AetherDesign.Palette.textSecondary)
            Text("Requesting a code from plex.tv…")
                .font(AetherDesign.Typography.body)
                .foregroundStyle(AetherDesign.Palette.textSecondary)
        }
    }

    private func awaitingUserView(pin: PlexAPI.PIN, url: URL) -> some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
            // Big readable code — couch-distance on tvOS, glanceable on iOS.
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
                Text("Your code")
                    .font(AetherDesign.Typography.caption)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
                Text(pin.code)
                    .font(.system(size: 56, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .kerning(8)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
            }

            // Two paths: direct link (iOS) and QR (both).
            HStack(alignment: .top, spacing: AetherDesign.Spacing.xl) {
                VStack(alignment: .leading, spacing: AetherDesign.Spacing.s) {
                    Text("Enter the code at")
                        .font(AetherDesign.Typography.body)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                    Text("plex.tv/link")
                        .font(AetherDesign.Typography.cardTitle)
                        .foregroundStyle(AetherDesign.Palette.textPrimary)

                    #if os(iOS)
                    Button {
                        openURL(url)
                    } label: {
                        Text("Open in Safari")
                            .font(AetherDesign.Typography.cardTitle)
                            .padding(.horizontal, AetherDesign.Spacing.l)
                            .padding(.vertical, AetherDesign.Spacing.s)
                            .background(AetherDesign.Palette.accent.opacity(0.20), in: Capsule())
                            .foregroundStyle(AetherDesign.Palette.textPrimary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, AetherDesign.Spacing.s)
                    #endif
                }

                VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
                    Text("Or scan with another device")
                        .font(AetherDesign.Typography.caption)
                        .foregroundStyle(AetherDesign.Palette.textTertiary)
                    QRCodeView(message: url.absoluteString)
                        .frame(width: 180, height: 180)
                        .padding(AetherDesign.Spacing.s)
                        .background(.white, in: RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous))
                }
            }

            HStack(spacing: AetherDesign.Spacing.s) {
                ProgressView()
                    .tint(AetherDesign.Palette.textSecondary)
                Text("Waiting for you to enter the code…")
                    .font(AetherDesign.Typography.metadata)
                    .foregroundStyle(AetherDesign.Palette.textSecondary)
            }
        }
    }

    private var successView: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.s) {
            HStack(spacing: AetherDesign.Spacing.s) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(AetherDesign.Palette.accent)
                Text("Signed in")
                    .font(AetherDesign.Typography.sectionTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
            }
            Text("Looking for your servers next.")
                .font(AetherDesign.Typography.body)
                .foregroundStyle(AetherDesign.Palette.textSecondary)
        }
    }

    private func failureView(reason: PlexSignInViewModel.FailureReason) -> some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.s) {
            HStack(spacing: AetherDesign.Spacing.s) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(AetherDesign.Palette.textSecondary)
                Text(title(for: reason))
                    .font(AetherDesign.Typography.sectionTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
            }
            Text(message(for: reason))
                .font(AetherDesign.Typography.body)
                .foregroundStyle(AetherDesign.Palette.textSecondary)

            Button {
                viewModel.retry()
            } label: {
                Text("Try again")
                    .font(AetherDesign.Typography.cardTitle)
                    .padding(.horizontal, AetherDesign.Spacing.l)
                    .padding(.vertical, AetherDesign.Spacing.s)
                    .background(AetherDesign.Palette.accent.opacity(0.20), in: Capsule())
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
            }
            .buttonStyle(.plain)
            .padding(.top, AetherDesign.Spacing.s)
        }
    }

    // MARK: - Cancel

    private var cancelButton: some View {
        Button {
            viewModel.cancel()
            onCancel()
        } label: {
            Text("Cancel")
                .font(AetherDesign.Typography.metadata)
                .foregroundStyle(AetherDesign.Palette.textSecondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private var stateIsSuccess: Bool {
        if case .success = viewModel.state { return true }
        return false
    }

    private func title(for reason: PlexSignInViewModel.FailureReason) -> String {
        switch reason {
        case .expired:  return "Code expired"
        case .timedOut: return "Sign-in timed out"
        case .network:  return "Couldn't reach plex.tv"
        }
    }

    private func message(for reason: PlexSignInViewModel.FailureReason) -> String {
        switch reason {
        case .expired:
            return "Codes are valid for a few minutes. Request a new one."
        case .timedOut:
            return "We waited five minutes without seeing a sign-in. Request a new code and try again."
        case let .network(message):
            return message
        }
    }
}
