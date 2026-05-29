import SwiftUI
import AetherCore

/// The second step of Plex onboarding — runs after a successful PIN sign-in.
///
/// Four user-visible states (driven by `AppSession.DiscoveryState`):
/// - **discovering** — calm progress message, no spinner shouting.
/// - **noServersFound** — designed empty state with `Try again` + `Close`.
/// - **failed** — designed error state with the underlying message + retry.
/// - **completed** — server name confirmed, single `Done` button.
///
/// Same shell on iOS and tvOS. The selection / discovery work is `AppSession`'s
/// — this view just reads its state and offers `onRetry` / `onClose` callbacks.
struct PlexDiscoveryView: View {
    let state: AppSession.DiscoveryState
    let onRetry: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack {
            AetherDesign.Palette.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                header

                Spacer(minLength: 0)

                content

                Spacer(minLength: 0)

                footer
            }
            .frame(maxWidth: 720, maxHeight: .infinity, alignment: .topLeading)
            .padding(AetherDesign.Spacing.xl)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
            Text("Finding your servers")
                .font(AetherDesign.Typography.heroTitle)
                .foregroundStyle(AetherDesign.Palette.textPrimary)
            Text("Aether asks Plex which servers your account can reach.")
                .font(AetherDesign.Typography.metadata)
                .foregroundStyle(AetherDesign.Palette.textSecondary)
        }
    }

    // MARK: - Per-state content

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .discovering:
            discoveringView
        case .noServersFound:
            noServersView
        case let .failed(message):
            failedView(message: message)
        case let .completed(serverName):
            completedView(serverName: serverName)
        }
    }

    private var discoveringView: some View {
        HStack(spacing: AetherDesign.Spacing.s) {
            ProgressView()
                .tint(AetherDesign.Palette.textSecondary)
            Text("Looking for your Plex servers…")
                .font(AetherDesign.Typography.body)
                .foregroundStyle(AetherDesign.Palette.textSecondary)
        }
    }

    private var noServersView: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(AetherDesign.Palette.textTertiary)

            Text("No servers found")
                .font(AetherDesign.Typography.sectionTitle)
                .foregroundStyle(AetherDesign.Palette.textPrimary)

            Text("Your Plex account isn't connected to any reachable servers right now. If a server should be visible, check that it's powered on and signed in to the same Plex account.")
                .font(AetherDesign.Typography.body)
                .foregroundStyle(AetherDesign.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func failedView(message: String) -> some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(AetherDesign.Palette.textSecondary)

            Text("Couldn't reach Plex")
                .font(AetherDesign.Typography.sectionTitle)
                .foregroundStyle(AetherDesign.Palette.textPrimary)

            Text(message)
                .font(AetherDesign.Typography.body)
                .foregroundStyle(AetherDesign.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func completedView(serverName: String) -> some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            HStack(spacing: AetherDesign.Spacing.s) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(AetherDesign.Palette.accent)
                Text("Connected")
                    .font(AetherDesign.Typography.sectionTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
            }

            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xxs) {
                Text(serverName)
                    .font(AetherDesign.Typography.cardTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                Text("Library browsing arrives in the next update.")
                    .font(AetherDesign.Typography.body)
                    .foregroundStyle(AetherDesign.Palette.textSecondary)
            }
        }
    }

    // MARK: - Footer (state-aware actions)

    private var footer: some View {
        HStack(spacing: AetherDesign.Spacing.m) {
            switch state {
            case .idle, .discovering:
                Spacer()
                Button("Cancel", action: onClose)
                    .buttonStyle(.plain)
                    .font(AetherDesign.Typography.metadata)
                    .foregroundStyle(AetherDesign.Palette.textSecondary)

            case .noServersFound, .failed:
                Button("Close", action: onClose)
                    .buttonStyle(.plain)
                    .font(AetherDesign.Typography.metadata)
                    .foregroundStyle(AetherDesign.Palette.textSecondary)
                Spacer()
                primaryButton(title: "Try again", action: onRetry)

            case .completed:
                Spacer()
                primaryButton(title: "Done", action: onClose)
            }
        }
    }

    private func primaryButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(AetherDesign.Typography.cardTitle)
                .padding(.horizontal, AetherDesign.Spacing.l)
                .padding(.vertical, AetherDesign.Spacing.s)
                .background(AetherDesign.Palette.accent.opacity(0.20), in: Capsule())
                .foregroundStyle(AetherDesign.Palette.textPrimary)
        }
        .buttonStyle(.plain)
    }
}
