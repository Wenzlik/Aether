import SwiftUI
import AetherCore

// MARK: - Settings preference sheets (split from SettingsView.swift, #415)

extension SettingsView {
    // MARK: - Preference sheets

    @ViewBuilder
    func preferenceSheet(for picker: PrefPicker) -> some View {
        switch picker {
        case .quality:        qualityPickerSheet
        case .audio:          audioLanguagePickerSheet
        case .subtitles:      subtitlePickerSheet
        case .appearance:     appearancePickerSheet
        case .language:       languagePickerSheet
        case .skipIntro:      skipModePickerSheet(title: "Skip Intro", selection: \.skipIntro)
        case .skipCredits:    skipModePickerSheet(title: "Skip Credits", selection: \.skipCredits)
        case .autoPlayNext:   autoPlayNextPickerSheet
        case .countdown:      countdownPickerSheet
        case .watchedDimming: watchedDimmingPickerSheet
        case .watchedLabelOpacity: watchedLabelOpacityPickerSheet
        case .posterRatingSource: posterRatingSourcePickerSheet
        case .netflixRegion: netflixRegionPickerSheet
        #if os(iOS)
        case .appIcon: appIconPickerSheet
        #endif
        #if os(visionOS)
        case .cinemaScreen:
            cinemaPickerSheet(title: "Default Screen Size", options: CinemaScreenPreset.ordered, label: \.displayName, selection: Binding(
                get: { viewModel.cinemaPreferences.defaultScreenPreset },
                set: { viewModel.cinemaPreferences.defaultScreenPreset = $0 }
            ))
        case .cinemaSeat:
            cinemaPickerSheet(title: "Default Seating", options: CinemaSeat.ordered, label: \.displayName, selection: Binding(
                get: { viewModel.cinemaPreferences.defaultSeat },
                set: { viewModel.cinemaPreferences.defaultSeat = $0 }
            ))
        case .cinemaEnvironment:
            cinemaPickerSheet(title: "Environment", options: CinemaEnvironment.available, label: \.displayName, selection: Binding(
                get: { viewModel.cinemaPreferences.environment },
                set: { viewModel.cinemaPreferences.environment = $0 }
            ))
        #endif
        }
    }

    #if os(visionOS)
    /// Cinema preference picker — same sheet pattern as every other Settings
    /// picker (replaces the old inline `.menu`).
    private func cinemaPickerSheet<T: Hashable>(
        title: String,
        options: [T],
        label: @escaping (T) -> String,
        selection: Binding<T>
    ) -> some View {
        PreferencePickerSheet(title: title) {
            ForEach(options, id: \.self) { option in
                AetherSelectionRow(title: label(option), isSelected: selection.wrappedValue == option) {
                    selection.wrappedValue = option
                    openPicker = nil
                }
            }
        }
    }
    #endif

    #if os(iOS)
    private var appIconPickerSheet: some View {
        PreferencePickerSheet(title: "App Icon") {
            ForEach(AetherAppIcon.allCases) { icon in
                AetherSelectionRow(
                    title: icon.displayName,
                    isSelected: appIconStore.current == icon
                ) {
                    appIconStore.select(icon)
                    openPicker = nil
                }
            }
        }
    }
    #endif

    private var watchedDimmingPickerSheet: some View {
        PreferencePickerSheet(title: "Watched Dimming") {
            ForEach(WatchedDimming.allCases, id: \.self) { level in
                AetherSelectionRow(
                    title: level.displayName,
                    isSelected: viewModel.playbackPreferences.watchedDimming == level
                ) {
                    viewModel.playbackPreferences.watchedDimming = level
                    openPicker = nil
                }
            }
        }
    }

    private var posterRatingSourcePickerSheet: some View {
        PreferencePickerSheet(title: "Poster Rating") {
            ForEach(PosterRatingSource.allCases, id: \.self) { source in
                AetherSelectionRow(
                    title: source.displayName,
                    isSelected: viewModel.playbackPreferences.posterRatingSource == source
                ) {
                    viewModel.playbackPreferences.posterRatingSource = source
                    openPicker = nil
                }
            }
        }
    }

    private var watchedLabelOpacityPickerSheet: some View {
        PreferencePickerSheet(title: "Label Opacity") {
            ForEach(WatchedLabelOpacity.allCases, id: \.self) { level in
                AetherSelectionRow(
                    title: level.displayName,
                    isSelected: abs(viewModel.playbackPreferences.watchedLabelOpacity - level.value) < 0.05
                ) {
                    viewModel.playbackPreferences.watchedLabelOpacity = level.value
                    openPicker = nil
                }
            }
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
                    detail: appearanceDetail(for: option),
                    isSelected: viewModel.appearance.preference == option
                ) {
                    viewModel.appearance.preference = option
                    openPicker = nil
                }
            }
        }
    }

    private func appearanceDetail(for option: AppearancePreference) -> String? {
        #if os(tvOS)
        return option == .dark ? "Recommended for Apple TV" : nil
        #else
        return nil
        #endif
    }

    private var languagePickerSheet: some View {
        PreferencePickerSheet(title: "Language") {
            ForEach(AppLanguage.available, id: \.self) { language in
                AetherSelectionRow(
                    title: language.displayName,
                    isSelected: viewModel.language.preference == language
                ) {
                    viewModel.language.preference = language
                    openPicker = nil
                }
            }
        }
    }

    private func skipModePickerSheet(
        title: String,
        selection keyPath: ReferenceWritableKeyPath<PlaybackPreferencesStore, SkipMode>
    ) -> some View {
        PreferencePickerSheet(title: title) {
            ForEach(SkipMode.allCases, id: \.self) { option in
                AetherSelectionRow(
                    title: option.displayName,
                    isSelected: viewModel.playbackPreferences[keyPath: keyPath] == option
                ) {
                    viewModel.playbackPreferences[keyPath: keyPath] = option
                    openPicker = nil
                }
            }
        }
    }

    private var autoPlayNextPickerSheet: some View {
        PreferencePickerSheet(title: "Auto-Play Next Episode") {
            ForEach([true, false], id: \.self) { on in
                AetherSelectionRow(
                    title: on ? "On" : "Off",
                    isSelected: viewModel.playbackPreferences.autoPlayNext == on
                ) {
                    viewModel.playbackPreferences.autoPlayNext = on
                    openPicker = nil
                }
            }
        }
    }

    private var countdownPickerSheet: some View {
        PreferencePickerSheet(title: "Next Episode Countdown") {
            ForEach(PlaybackPreferencesStore.countdownOptions, id: \.self) { seconds in
                AetherSelectionRow(
                    title: "\(seconds) seconds",
                    isSelected: viewModel.playbackPreferences.nextEpisodeCountdown == seconds
                ) {
                    viewModel.playbackPreferences.nextEpisodeCountdown = seconds
                    openPicker = nil
                }
            }
        }
    }
}

/// Bottom-sheet container reused by every Settings preference picker
/// (Default Quality, Default Audio Language, Default Subtitle Language,
/// Appearance). Mirrors the Detail-screen picker pattern: title row at
/// the top, `AetherSelectionRow`s in a scrollable list. `.medium` /
/// `.large` detents so the user can pull it up when the list is long
/// (the language list runs to 15+ rows).
struct PreferencePickerSheet<Content: View>: View {
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
        .aetherScreenBackground()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// The **What's New** modal opened from the About → Version row. A headline,
/// the version it covers, and the shipped highlights as a checked bullet list.
/// Mirrors `PreferencePickerSheet`'s container so the two modals feel identical.
struct WhatsNewSheet: View {
    let version: String
    let codename: String
    let bullets: [String]
    var history: [ReleaseNote] = []
    let onClose: () -> Void

    /// Previous releases (everything but the current version).
    private var pastReleases: [ReleaseNote] {
        history.filter { $0.version != version }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xxs) {
                Text("What's New")
                    .font(AetherDesign.Typography.heroTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                Text("Version \(version) · “\(codename)”")
                    .font(AetherDesign.Typography.metadata)
                    .foregroundStyle(AetherDesign.Palette.textSecondary)
            }
            .padding(.horizontal, AetherDesign.Spacing.l)
            .padding(.top, AetherDesign.Spacing.l)

            ScrollView {
              VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
                    ForEach(bullets, id: \.self) { bullet in
                        HStack(alignment: .firstTextBaseline, spacing: AetherDesign.Spacing.s) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(AetherDesign.Typography.body)
                                .foregroundStyle(AetherDesign.Palette.success)
                            Text(bullet)
                                .font(AetherDesign.Typography.body)
                                .foregroundStyle(AetherDesign.Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(AetherDesign.Spacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                        .fill(AetherDesign.Materials.card)
                )
                .padding(.horizontal, AetherDesign.Spacing.l)
                // tvOS scrolls by MOVING focus between items — so each card is a
                // focus stop. A single focusable scroll body (the old approach)
                // left focus stuck on Done and the release notes unreachable.
                .tvOSScrollFocusable()

                if !pastReleases.isEmpty {
                    VStack(alignment: .leading, spacing: AetherDesign.Spacing.s) {
                        Text("RELEASE HISTORY")
                            .font(AetherDesign.Typography.caption)
                            .foregroundStyle(AetherDesign.Palette.textTertiary)
                            .tracking(0.6)
                        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
                            ForEach(pastReleases) { release in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(release.codename.map { "\(release.version) · \($0)" } ?? release.version)
                                        .font(AetherDesign.Typography.cardTitle)
                                        .foregroundStyle(AetherDesign.Palette.textPrimary)
                                    Text(release.summary)
                                        .font(AetherDesign.Typography.metadata)
                                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .tvOSScrollFocusable()   // a focus stop per release so the remote scrolls through history
                            }
                        }
                        .padding(AetherDesign.Spacing.l)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                                .fill(AetherDesign.Materials.card)
                        )
                    }
                    .padding(.horizontal, AetherDesign.Spacing.l)
                    .padding(.top, AetherDesign.Spacing.s)
                }
                #if os(tvOS)
                // On tvOS, Done sits at the END of the scroll so the remote
                // reaches it by moving Down past the notes — a sibling below the
                // ScrollView is unreachable once focus is inside it (#266).
                AetherButton("Done", role: .secondary, action: onClose)
                    .padding(.horizontal, AetherDesign.Spacing.l)
                    .padding(.top, AetherDesign.Spacing.l)
                #endif
              }
            }

            #if !os(tvOS)
            AetherButton("Done", role: .secondary, action: onClose)
                .padding(.horizontal, AetherDesign.Spacing.l)
                .padding(.bottom, AetherDesign.Spacing.l)
            #endif
        }
        .aetherScreenBackground()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
