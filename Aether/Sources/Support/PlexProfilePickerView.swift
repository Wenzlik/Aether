import SwiftUI
import AetherCore

/// Plex Home profile chooser — a grid of avatars used both in the sign-in flow
/// and the Settings "Switch Profile" sheet. Self-contained PIN handling: tapping
/// a PIN-protected profile reveals a PIN field; everything else switches
/// immediately. The owner performs the actual switch via `onChoose` and feeds
/// back `isSwitching` / `pinError`.
struct PlexProfilePickerView: View {
    let users: [PlexAPI.HomeUser]
    /// A switch is in flight — disable interaction + show progress.
    let isSwitching: Bool
    /// The last switch failed on a wrong/missing PIN — re-prompt.
    let pinError: Bool
    /// Perform the switch. `pin` is `nil` for unprotected profiles.
    let onChoose: (PlexAPI.HomeUser, String?) -> Void

    @State private var pinUser: PlexAPI.HomeUser?
    @State private var pin: String = ""

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: AetherDesign.Spacing.l)]

    var body: some View {
        if let pinUser {
            pinEntry(for: pinUser)
        } else {
            grid
        }
    }

    // MARK: - Grid

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: AetherDesign.Spacing.l) {
            ForEach(users) { user in
                Button {
                    if user.isProtected {
                        pin = ""
                        pinUser = user
                    } else {
                        onChoose(user, nil)
                    }
                } label: {
                    profileCell(user)
                }
                .buttonStyle(.plain)
                .disabled(isSwitching)
            }
        }
    }

    private func profileCell(_ user: PlexAPI.HomeUser) -> some View {
        VStack(spacing: AetherDesign.Spacing.s) {
            avatar(for: user)
            Text(user.title)
                .font(AetherDesign.Typography.cardTitle)
                .foregroundStyle(AetherDesign.Palette.textPrimary)
                .lineLimit(1)
            if user.isProtected {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
            }
        }
    }

    private func avatar(for user: PlexAPI.HomeUser) -> some View {
        ZStack {
            Circle().fill(AetherDesign.Palette.accent.opacity(0.18))
            if let thumb = user.thumb, let url = URL(string: thumb) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    initials(for: user)
                }
                .clipShape(Circle())
            } else {
                initials(for: user)
            }
        }
        .frame(width: 96, height: 96)
        .overlay(Circle().strokeBorder(AetherDesign.Palette.accent.opacity(0.4), lineWidth: 1))
    }

    private func initials(for user: PlexAPI.HomeUser) -> some View {
        Text(String(user.title.prefix(1)).uppercased())
            .font(.system(size: 36, weight: .semibold, design: .rounded))
            .foregroundStyle(AetherDesign.Palette.textPrimary)
    }

    // MARK: - PIN entry

    private func pinEntry(for user: PlexAPI.HomeUser) -> some View {
        VStack(spacing: AetherDesign.Spacing.l) {
            avatar(for: user)
            Text(user.title)
                .font(AetherDesign.Typography.sectionTitle)
                .foregroundStyle(AetherDesign.Palette.textPrimary)
            Text("Enter this profile's PIN")
                .font(AetherDesign.Typography.metadata)
                .foregroundStyle(AetherDesign.Palette.textSecondary)

            SecureField("PIN", text: $pin)
                .textContentType(.oneTimeCode)
                #if !os(tvOS)
                .keyboardType(.numberPad)
                #endif
                .multilineTextAlignment(.center)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .frame(maxWidth: 220)
                .padding(AetherDesign.Spacing.s)
                .background(AetherDesign.Palette.surface, in: RoundedRectangle(cornerRadius: AetherDesign.Radius.card))
                .onSubmit { submit(user) }

            if pinError {
                Text("Wrong PIN. Try again.")
                    .font(AetherDesign.Typography.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: AetherDesign.Spacing.m) {
                Button("Back") {
                    pinUser = nil
                    pin = ""
                }
                .buttonStyle(.plain)
                .foregroundStyle(AetherDesign.Palette.textSecondary)

                Button {
                    submit(user)
                } label: {
                    HStack(spacing: AetherDesign.Spacing.xs) {
                        if isSwitching { ProgressView().tint(AetherDesign.Palette.textPrimary) }
                        Text("Continue")
                    }
                    .font(AetherDesign.Typography.cardTitle)
                    .padding(.horizontal, AetherDesign.Spacing.l)
                    .padding(.vertical, AetherDesign.Spacing.s)
                    .background(AetherDesign.Palette.accent.opacity(0.20), in: Capsule())
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                }
                .buttonStyle(.plain)
                .disabled(pin.isEmpty || isSwitching)
            }
        }
    }

    private func submit(_ user: PlexAPI.HomeUser) {
        guard !pin.isEmpty, !isSwitching else { return }
        onChoose(user, pin)
    }
}

/// Settings sheet that swaps the active Plex Home profile at runtime. Loads the
/// account's profiles, then drives `PlexProfilePickerView`; a successful switch
/// re-runs discovery (handled in `AppSession`) and dismisses.
struct PlexProfileSwitchSheet: View {
    let viewModel: SettingsViewModel
    let onClose: () -> Void

    @State private var users: [PlexAPI.HomeUser] = []
    @State private var loading = true
    @State private var isSwitching = false
    @State private var pinError = false

    var body: some View {
        ScrollView {
            VStack(spacing: AetherDesign.Spacing.xl) {
                Text("Switch Profile")
                    .font(AetherDesign.Typography.heroTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if loading {
                    ProgressView().tint(AetherDesign.Palette.textSecondary)
                } else if users.count <= 1 {
                    Text("No other profiles on this account.")
                        .font(AetherDesign.Typography.body)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                } else {
                    PlexProfilePickerView(
                        users: users,
                        isSwitching: isSwitching,
                        pinError: pinError,
                        onChoose: choose
                    )
                }

                Button("Done") { onClose() }
                    .buttonStyle(.plain)
                    .foregroundStyle(AetherDesign.Palette.textSecondary)
            }
            .padding(AetherDesign.Spacing.l)
            .frame(maxWidth: AetherSheetLayout.maxContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .tvOSScrollFocusable()
        }
        .task {
            users = await viewModel.plexHomeUsers()
            loading = false
        }
    }

    private func choose(_ user: PlexAPI.HomeUser, _ pin: String?) {
        isSwitching = true
        pinError = false
        Task {
            do {
                try await viewModel.switchPlexProfile(user, pin: pin)
                isSwitching = false
                onClose()
            } catch PlexHomeError.invalidPIN {
                isSwitching = false
                pinError = true
            } catch {
                isSwitching = false
                onClose()
            }
        }
    }
}
