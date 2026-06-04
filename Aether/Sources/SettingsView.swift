import SwiftUI
import AetherCore

/// Aether's settings surface — a full-screen tab destination (no longer a
/// modal). Calm, factual, four grouped focusable cards: Account, Sources,
/// Playback, About. Status values are colour-coded (Available / Not connected /
/// Coming soon) so connection state reads at couch distance. Sign-out is the
/// only destructive action. See `docs/ux/DESIGN_PRINCIPLES.md` → *Settings*.
struct SettingsView: View {
    @State var viewModel: SettingsViewModel
    @State private var isSigningOut = false
    @State private var isSigningOutJellyfin = false
    @State private var isWhatsNewExpanded = false
    @State private var openPicker: PrefPicker?

    /// Identifier for whichever default-pref sheet is open. Driven via
    /// `.sheet(item:)` so the picker contents reflect the row tapped.
    private enum PrefPicker: String, Identifiable {
        case quality, audio, subtitles, appearance
        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            AetherDesign.Gradients.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                    header
                    accountSection
                    sourcesSection
                    playbackSection
                    appearanceSection
                    aboutSection
                }
                .padding(.horizontal, AetherDesign.Spacing.l)
                .padding(.top, AetherDesign.Spacing.l)
                .padding(.bottom, AetherDesign.Spacing.xxl)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(item: $openPicker) { picker in
            preferenceSheet(for: picker)
        }
    }

    // MARK: - Header

    /// Settings header: a centred Aether lockup matching the Home / Library
    /// chrome, then content. The "Settings" page title and the explanatory
    /// subtitle were dropped — the selected tab in the bottom bar tells the
    /// user where they are, and the screen reads more like a premium
    /// dashboard than a Preferences pane when it doesn't open with a
    /// label + paragraph of explanation.
    private var header: some View {
        AetherWordmark(.large)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Sections

    private var accountSection: some View {
        AetherSettingsSection("Account") {
            AetherSettingsRow(
                label: "Plex",
                systemImage: "play.circle.fill",
                status: viewModel.plexAccountStatus,
                action: viewModel.isPlexSignedIn ? nil : { viewModel.connect() }
            )

            if let serverDetail = viewModel.connectedServerDetail {
                AetherSettingsRow(label: serverDetail, systemImage: "server.rack", value: nil)
            }

            if viewModel.isPlexSignedIn {
                AetherSettingsRow(
                    label: isSigningOut ? "Signing out…" : "Sign Out of Plex",
                    systemImage: "rectangle.portrait.and.arrow.right",
                    actionRole: .destructive
                ) {
                    Task { await performSignOut() }
                }
                .disabled(isSigningOut)
            }

            if viewModel.isJellyfinSignedIn {
                AetherSettingsRow(
                    label: "Jellyfin",
                    systemImage: "rectangle.stack.badge.play.fill",
                    status: .connected
                )
                if let name = viewModel.jellyfinServerName {
                    AetherSettingsRow(label: "Server: \(name)", systemImage: "server.rack", value: nil)
                }
                AetherSettingsRow(
                    label: isSigningOutJellyfin ? "Signing out…" : "Sign Out of Jellyfin",
                    systemImage: "rectangle.portrait.and.arrow.right",
                    actionRole: .destructive
                ) {
                    Task { await performSignOutJellyfin() }
                }
                .disabled(isSigningOutJellyfin)
            }
        }
    }

    private var sourcesSection: some View {
        AetherSettingsSection("Sources") {
            sourceRow(
                kind: .plex,
                label: "Plex",
                glyph: "play.circle.fill",
                connected: viewModel.isPlexSignedIn,
                connect: { viewModel.connect() }
            )
            sourceRow(
                kind: .jellyfin,
                label: "Jellyfin",
                glyph: "rectangle.stack.badge.play.fill",
                connected: viewModel.isJellyfinSignedIn,
                connect: { viewModel.connectJellyfin() }
            )
            AetherSettingsRow(label: "Synology", systemImage: "externaldrive.fill", status: viewModel.synologyStatus)
        }
    }

    /// One source row: tap to connect when disconnected, or — when both sources
    /// are connected — tap to make this the active (browsed) source. The active
    /// one reads "Active".
    private func sourceRow(
        kind: AppSession.SourceKind,
        label: String,
        glyph: String,
        connected: Bool,
        connect: @escaping () -> Void
    ) -> AetherSettingsRow {
        let status: AetherStatus
        if !connected {
            status = .notConnected
        } else if viewModel.canSwitchSources {
            status = viewModel.isActiveSource(kind) ? .positive("Active") : .connected
        } else {
            status = .connected
        }

        let action: (() -> Void)?
        if !connected {
            action = connect
        } else if viewModel.canSwitchSources && !viewModel.isActiveSource(kind) {
            action = { viewModel.setActive(kind) }
        } else {
            action = nil
        }

        return AetherSettingsRow(label: label, systemImage: glyph, status: status, action: action)
    }

    // MARK: - Playback prefs

    /// New Playback section — three disclosure rows that open sheet pickers
    /// to set the **defaults** carried into every Detail screen's Audio /
    /// Subtitles / Quality pickers. The old capability badges
    /// (Direct Play / Transcoding / Offline Downloads) lived here too but
    /// were product facts, not preferences — Settings should hold
    /// configurable choices, not boast about what the app can do.
    private var playbackSection: some View {
        AetherSettingsSection("Playback") {
            AetherDisclosureRow(
                label: "Default Quality",
                value: viewModel.playbackPreferences.defaultQuality.displayName,
                systemImage: "slider.horizontal.3"
            ) {
                openPicker = .quality
            }
            AetherDisclosureRow(
                label: "Audio Language",
                value: languageLabel(viewModel.playbackPreferences.defaultAudioLanguage),
                systemImage: "speaker.wave.2.fill"
            ) {
                openPicker = .audio
            }
            AetherDisclosureRow(
                label: "Subtitle Language",
                value: subtitleLabel(viewModel.playbackPreferences.defaultSubtitleLanguage),
                systemImage: "captions.bubble.fill"
            ) {
                openPicker = .subtitles
            }
        }
    }

    // MARK: - Appearance

    /// Standard System / Dark / Light triplet, applied at the app root via
    /// `.preferredColorScheme(_:)`. The picker is wired today; the Light
    /// palette tokens needed to make Light mode actually look good ship in
    /// a separate visual pass — for now selecting Light flips the system
    /// chrome but the dark-encoded `Palette` colours stay dark.
    private var appearanceSection: some View {
        AetherSettingsSection("Appearance") {
            AetherDisclosureRow(
                label: "Theme",
                value: viewModel.appearance.preference.displayName,
                systemImage: "paintbrush.fill"
            ) {
                openPicker = .appearance
            }
        }
    }

    // MARK: - Preference sheets

    @ViewBuilder
    private func preferenceSheet(for picker: PrefPicker) -> some View {
        switch picker {
        case .quality:        qualityPickerSheet
        case .audio:          audioLanguagePickerSheet
        case .subtitles:      subtitlePickerSheet
        case .appearance:     appearancePickerSheet
        }
    }

    private var qualityPickerSheet: some View {
        PreferencePickerSheet(title: "Default Quality") {
            ForEach(PlaybackQuality.allCases, id: \.self) { quality in
                AetherSelectionRow(
                    title: quality.displayName,
                    isSelected: viewModel.playbackPreferences.defaultQuality == quality
                ) {
                    viewModel.playbackPreferences.defaultQuality = quality
                    openPicker = nil
                }
            }
        }
    }

    private var audioLanguagePickerSheet: some View {
        PreferencePickerSheet(title: "Default Audio Language") {
            AetherSelectionRow(
                title: "Follow source default",
                isSelected: viewModel.playbackPreferences.defaultAudioLanguage == nil
            ) {
                viewModel.playbackPreferences.defaultAudioLanguage = nil
                openPicker = nil
            }
            ForEach(PlaybackLanguage.common, id: \.code) { language in
                AetherSelectionRow(
                    title: language.displayName,
                    isSelected: viewModel.playbackPreferences.defaultAudioLanguage == language.code
                ) {
                    viewModel.playbackPreferences.defaultAudioLanguage = language.code
                    openPicker = nil
                }
            }
        }
    }

    private var subtitlePickerSheet: some View {
        PreferencePickerSheet(title: "Default Subtitle Language") {
            AetherSelectionRow(
                title: "Follow source default",
                isSelected: viewModel.playbackPreferences.defaultSubtitleLanguage == nil
            ) {
                viewModel.playbackPreferences.defaultSubtitleLanguage = nil
                openPicker = nil
            }
            AetherSelectionRow(
                title: "Off",
                isSelected: viewModel.playbackPreferences.defaultSubtitleLanguage == "off"
            ) {
                viewModel.playbackPreferences.defaultSubtitleLanguage = "off"
                openPicker = nil
            }
            ForEach(PlaybackLanguage.common, id: \.code) { language in
                AetherSelectionRow(
                    title: language.displayName,
                    isSelected: viewModel.playbackPreferences.defaultSubtitleLanguage == language.code
                ) {
                    viewModel.playbackPreferences.defaultSubtitleLanguage = language.code
                    openPicker = nil
                }
            }
        }
    }

    private var appearancePickerSheet: some View {
        PreferencePickerSheet(title: "Appearance") {
            ForEach(AppearancePreference.allCases, id: \.self) { option in
                AetherSelectionRow(
                    title: option.displayName,
                    isSelected: viewModel.appearance.preference == option
                ) {
                    viewModel.appearance.preference = option
                    openPicker = nil
                }
            }
        }
    }

    /// Display string for an audio-language preference. Empty / nil renders
    /// as "Source default" so the row never reads blank.
    private func languageLabel(_ code: String?) -> String {
        guard let code, !code.isEmpty else { return "Source default" }
        return PlaybackLanguage.displayName(for: code)
    }

    /// Display string for a subtitle-language preference — extends the
    /// audio handling with an "Off" sentinel.
    private func subtitleLabel(_ code: String?) -> String {
        guard let code, !code.isEmpty else { return "Source default" }
        if code == "off" { return "Off" }
        return PlaybackLanguage.displayName(for: code)
    }

    /// Compact About.
    ///
    /// **iOS / iPadOS / visionOS:** one tappable Version row that expands
    /// to show a cumulative "What's New" bullet list of shipped highlights.
    /// Vertical space is the constraint; collapse-by-default keeps the
    /// section from dominating the bottom of Settings.
    ///
    /// **tvOS:** vertical space is even more constrained (Settings
    /// scrolls but D-pad focus doesn't move into static text), so the
    /// disclosure pattern is replaced with a **two-column row** — the
    /// version label on the left, the What's New bullets always visible
    /// on the right where Settings' generous trailing whitespace would
    /// otherwise sit empty.
    private var aboutSection: some View {
        AetherSettingsSection("About") {
            #if os(tvOS)
            aboutRow_tvOS
            #else
            aboutRow_default
            #endif
        }
    }

    #if os(tvOS)
    /// tvOS About row: version on the left, bullets always-on on the
    /// right. Not tappable — there's no expand state to toggle.
    private var aboutRow_tvOS: some View {
        HStack(alignment: .top, spacing: AetherDesign.Spacing.xl) {
            HStack(spacing: AetherDesign.Spacing.m) {
                Image(systemName: "info.circle.fill")
                    .font(AetherDesign.Typography.body)
                    .foregroundStyle(AetherDesign.Palette.accent)
                    .frame(width: 28)
                Text(viewModel.versionRowLabel)
                    .font(AetherDesign.Typography.body)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                Spacer(minLength: AetherDesign.Spacing.s)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
                Text("What's New")
                    .font(AetherDesign.Typography.metadata)
                    .foregroundStyle(AetherDesign.Palette.textSecondary)
                ForEach(viewModel.whatsNewBullets, id: \.self) { bullet in
                    HStack(alignment: .firstTextBaseline, spacing: AetherDesign.Spacing.s) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AetherDesign.Palette.success)
                        Text(bullet)
                            .font(AetherDesign.Typography.metadata)
                            .foregroundStyle(AetherDesign.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(AetherDesign.Spacing.m)
    }
    #endif

    private var aboutRow_default: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.smooth(duration: 0.25)) {
                    isWhatsNewExpanded.toggle()
                }
            } label: {
                HStack(spacing: AetherDesign.Spacing.m) {
                    Image(systemName: "info.circle.fill")
                        .font(AetherDesign.Typography.body)
                        .foregroundStyle(AetherDesign.Palette.accent)
                        .frame(width: 28)

                    Text(viewModel.versionRowLabel)
                        .font(AetherDesign.Typography.body)
                        .foregroundStyle(AetherDesign.Palette.textPrimary)

                    Spacer(minLength: AetherDesign.Spacing.s)

                    Text("What's New")
                        .font(AetherDesign.Typography.metadata)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AetherDesign.Palette.textTertiary)
                        .rotationEffect(.degrees(isWhatsNewExpanded ? 90 : 0))
                }
                .padding(AetherDesign.Spacing.m)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(viewModel.versionRowLabel). What's New.")
            .accessibilityHint(isWhatsNewExpanded ? "Tap to collapse" : "Tap to expand")

            if isWhatsNewExpanded {
                VStack(alignment: .leading, spacing: AetherDesign.Spacing.s) {
                    ForEach(viewModel.whatsNewBullets, id: \.self) { bullet in
                        HStack(alignment: .firstTextBaseline, spacing: AetherDesign.Spacing.s) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AetherDesign.Palette.success)
                                .frame(width: 28)
                            Text(bullet)
                                .font(AetherDesign.Typography.metadata)
                                .foregroundStyle(AetherDesign.Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, AetherDesign.Spacing.m)
                .padding(.bottom, AetherDesign.Spacing.m)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Actions

    private func performSignOut() async {
        isSigningOut = true
        await viewModel.signOut()
        isSigningOut = false
    }

    private func performSignOutJellyfin() async {
        isSigningOutJellyfin = true
        await viewModel.signOutOfJellyfin()
        isSigningOutJellyfin = false
    }
}

/// Bottom-sheet container reused by every Settings preference picker
/// (Default Quality, Default Audio Language, Default Subtitle Language,
/// Appearance). Mirrors the Detail-screen picker pattern: title row at
/// the top, `AetherSelectionRow`s in a scrollable list. `.medium` /
/// `.large` detents so the user can pull it up when the list is long
/// (the language list runs to 15+ rows).
private struct PreferencePickerSheet<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            Text(title)
                .font(AetherDesign.Typography.sectionTitle)
                .foregroundStyle(AetherDesign.Palette.textPrimary)
                .padding(.horizontal, AetherDesign.Spacing.l)
                .padding(.top, AetherDesign.Spacing.l)

            ScrollView {
                VStack(spacing: 0) {
                    content()
                }
                .background(
                    RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                        .fill(AetherDesign.Materials.card)
                )
                .padding(.horizontal, AetherDesign.Spacing.l)
                .padding(.bottom, AetherDesign.Spacing.l)
            }
        }
        .background(AetherDesign.Palette.background.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
