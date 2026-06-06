import SwiftUI
import AetherCore

/// Aether's settings surface — a full-screen tab destination (no longer a
/// modal). Calm, factual, four grouped focusable cards: Account, Sources,
/// Playback, About. Status values are colour-coded (Available / Not connected /
/// Coming soon) so connection state reads at couch distance. Sign-out is the
/// only destructive action. See `docs/ux/DESIGN_PRINCIPLES.md` → *Settings*.
struct SettingsView: View {
    @State var viewModel: SettingsViewModel
    /// Dependencies for the **Settings → Downloads** destination (non-tvOS).
    /// Threaded through so the pushed download manager can resolve fresh URLs
    /// and drill into Detail. The three stores are always supplied by the app
    /// root; `source` / download pipeline are optional (nil pre-boot or when
    /// nothing is connected). Unused on tvOS (no downloads there).
    var source: (any MediaSource)?
    var resumeStore: ResumeStore
    var playbackSession: PlaybackSession
    var libraryPreferences: LibraryPreferencesStore
    var downloadManager: DownloadManager? = nil
    var downloads: DownloadObserver? = nil

    @State private var isSigningOut = false
    @State private var isSigningOutJellyfin = false
    @State private var isWhatsNewPresented = false
    @State private var openPicker: PrefPicker?
    /// Device volume stats for the Storage Summary card. `nil` until the probe
    /// runs (and stays nil if it fails) — the free-space row just hides.
    @State private var deviceCapacity: DeviceCapacity?
    /// Current on-disk artwork cache size, shown next to "Clear Image Cache".
    @State private var imageCacheBytes: Int = 0
    /// Drives the split: a two-column dashboard on roomy surfaces, a single
    /// column on the phone.
    @Environment(\.horizontalSizeClass) private var hSizeClass

    /// Identifier for whichever default-pref sheet is open. Driven via
    /// `.sheet(item:)` so the picker contents reflect the row tapped.
    private enum PrefPicker: String, Identifiable {
        case quality, audio, subtitles, appearance, skipIntro, skipCredits, autoPlayNext, countdown
        var id: String { rawValue }
    }

    /// Push targets inside the Settings stack.
    private enum SettingsRoute: Hashable {
        case downloads
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AetherDesign.Gradients.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                        header
                        if isWide {
                            wideDashboard
                        } else {
                            compactColumn
                        }
                    }
                    .padding(.horizontal, AetherDesign.Spacing.l)
                    .padding(.top, AetherDesign.Spacing.l)
                    .padding(.bottom, AetherDesign.Spacing.xxl)
                    .frame(maxWidth: isWide ? 1100 : 820, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .task {
                    await refreshCapacity()
                    imageCacheBytes = await Task.detached { AetherImageCache.shared.diskUsageBytes() }.value
                }
            }
            // The root Settings surface carries its own wordmark, so suppress the
            // empty navigation bar; pushed screens (Downloads) show their own.
            #if os(iOS) || os(visionOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            #if !os(tvOS)
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .downloads:
                    StorageView(
                        source: source,
                        resumeStore: resumeStore,
                        playbackSession: playbackSession,
                        libraryPreferences: libraryPreferences,
                        downloadManager: downloadManager,
                        downloads: downloads,
                        playbackPreferences: viewModel.playbackPreferences,
                        embedded: true
                    )
                }
            }
            #endif
        }
        .sheet(item: $openPicker) { picker in
            preferenceSheet(for: picker)
        }
        .sheet(isPresented: $isWhatsNewPresented) {
            WhatsNewSheet(
                version: viewModel.versionString,
                codename: viewModel.releaseCodename,
                bullets: viewModel.whatsNewBullets
            ) { isWhatsNewPresented = false }
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

    // MARK: - Layout

    /// `true` on roomy surfaces (iPad regular width, tvOS, visionOS) → render
    /// the two-column dashboard. iPhone (compact) stays single-column.
    private var isWide: Bool {
        #if os(tvOS) || os(visionOS)
        return true
        #else
        return hSizeClass == .regular
        #endif
    }

    /// iPad / tvOS / visionOS: controls on the left, an at-a-glance status
    /// dashboard (Connected Sources · Storage Summary) on the right — using the
    /// space instead of centring a phone-width list.
    private var wideDashboard: some View {
        HStack(alignment: .top, spacing: AetherDesign.Spacing.xl) {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                controlSections
            }
            .frame(maxWidth: .infinity, alignment: .top)
            // tvOS: mark each column a focus section so a Right/Left press jumps
            // between them. Without this, the right column's only focusable row
            // (Clear Image Cache, below non-focusable status rows) had no
            // horizontally-aligned target and focus could never reach it.
            .aetherFocusSection()

            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                dashboardCards
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .aetherFocusSection()
        }
    }

    /// iPhone: a single column. Source health lives inline in the Sources
    /// section (the Offline row), so the phone doesn't need the *status* cards
    /// the wide dashboard shows — but the **Cache** card has no other home, so
    /// it's appended here too (otherwise "Clear Image Cache" was invisible on
    /// iPhone, where only this column renders).
    private var compactColumn: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
            controlSections
            imageCacheCard
        }
    }

    @ViewBuilder
    private var controlSections: some View {
        accountSection
        sourcesSection
        #if !os(tvOS)
        downloadsSection
        #endif
        playbackSection
        appearanceSection
        aboutSection
    }

    @ViewBuilder
    private var dashboardCards: some View {
        connectedSourcesCard
        #if !os(tvOS)
        storageSummaryCard
        #endif
        imageCacheCard
    }

    /// Artwork disk-cache size + a manual clear. Auto-evicted under a cap too,
    /// but this gives the user direct control. All platforms (posters cache
    /// everywhere).
    private var imageCacheCard: some View {
        AetherSettingsSection("Cache") {
            AetherSettingsRow(
                label: "Clear Image Cache",
                systemImage: "photo.stack",
                value: formatBytes(Int64(imageCacheBytes))
            ) {
                AetherImageCache.shared.clear()
                imageCacheBytes = 0
            }
        }
    }

    // MARK: - Dashboard cards (status, right column)

    /// At-a-glance health for every source — Library shows *media*, Settings
    /// shows *sources*. Plex / Jellyfin read Online or Not connected; Offline
    /// reports the downloaded size (non-tvOS).
    private var connectedSourcesCard: some View {
        AetherSettingsSection("Connected Sources") {
            AetherSettingsRow(
                label: "Plex",
                systemImage: "play.circle.fill",
                status: viewModel.isPlexSignedIn ? .positive("Online") : .notConnected
            )
            AetherSettingsRow(
                label: "Jellyfin",
                systemImage: "rectangle.stack.badge.play.fill",
                status: viewModel.isJellyfinSignedIn ? .positive("Online") : .notConnected
            )
            #if !os(tvOS)
            AetherSettingsRow(
                label: "Offline",
                systemImage: "arrow.down.circle.fill",
                value: hasDownloads ? formatBytes(totalDownloadBytes) : "Empty"
            )
            #endif
        }
    }

    #if !os(tvOS)
    /// Device-level storage at a glance: how much Aether's downloads use, and
    /// how much room is left on the volume.
    private var storageSummaryCard: some View {
        AetherSettingsSection("Storage Summary") {
            AetherSettingsRow(
                label: "Downloads",
                systemImage: "internaldrive.fill",
                value: formatBytes(totalDownloadBytes)
            )
            if let capacity = deviceCapacity {
                AetherSettingsRow(
                    label: "Free Space",
                    systemImage: "externaldrive.badge.checkmark",
                    value: formatBytes(capacity.free)
                )
            }
        }
    }
    #endif

    // MARK: - Storage data

    private struct DeviceCapacity: Sendable {
        let free: Int64
        let total: Int64
    }

    /// Total bytes used by completed downloads. Summed from the observer's
    /// snapshot — same computation the download manager screen uses.
    private var totalDownloadBytes: Int64 {
        downloads?.snapshot.statusByJobID.values.reduce(0) { acc, status in
            if case let .completed(_, size) = status { return acc + size }
            return acc
        } ?? 0
    }

    private var hasDownloads: Bool {
        !(downloads?.snapshot.completed.isEmpty ?? true)
    }

    /// Read the volume Aether's downloads live on. Fails silently (capacity
    /// stays nil and the Free Space row just doesn't render).
    private func refreshCapacity() async {
        let path = NSHomeDirectory()
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let free = attrs[.systemFreeSize] as? NSNumber,
              let total = attrs[.systemSize] as? NSNumber else { return }
        deviceCapacity = DeviceCapacity(free: free.int64Value, total: total.int64Value)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        return formatter.string(fromByteCount: bytes)
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

    // MARK: - Downloads

    /// Entry point to the download manager — moved here from a top-level tab.
    /// Downloads are part of the source ecosystem now (an Offline source), not a
    /// separate area. tvOS has no downloads, so the section compiles out there.
    #if !os(tvOS)
    private var downloadsSection: some View {
        AetherSettingsSection("Downloads") {
            NavigationLink(value: SettingsRoute.downloads) {
                HStack(spacing: AetherDesign.Spacing.m) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(AetherDesign.Typography.body)
                        .foregroundStyle(AetherDesign.Palette.accent)
                        .frame(width: 28)
                    Text("Manage Downloads")
                        .font(AetherDesign.Typography.body)
                        .foregroundStyle(AetherDesign.Palette.textPrimary)
                    Spacer(minLength: AetherDesign.Spacing.s)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AetherDesign.Palette.textTertiary)
                }
                .padding(AetherDesign.Spacing.m)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
    #endif

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
            AetherDisclosureRow(
                label: "Skip Intro",
                value: viewModel.playbackPreferences.skipIntro.displayName,
                systemImage: "forward.end.fill"
            ) {
                openPicker = .skipIntro
            }
            AetherDisclosureRow(
                label: "Skip Credits",
                value: viewModel.playbackPreferences.skipCredits.displayName,
                systemImage: "forward.fill"
            ) {
                openPicker = .skipCredits
            }
            AetherDisclosureRow(
                label: "Auto-Play Next Episode",
                value: viewModel.playbackPreferences.autoPlayNext ? "On" : "Off",
                systemImage: "play.square.stack.fill"
            ) {
                openPicker = .autoPlayNext
            }
            AetherDisclosureRow(
                label: "Next Episode Countdown",
                value: "\(viewModel.playbackPreferences.nextEpisodeCountdown)s",
                systemImage: "timer"
            ) {
                openPicker = .countdown
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
        case .skipIntro:      skipModePickerSheet(title: "Skip Intro", selection: \.skipIntro)
        case .skipCredits:    skipModePickerSheet(title: "Skip Credits", selection: \.skipCredits)
        case .autoPlayNext:   autoPlayNextPickerSheet
        case .countdown:      countdownPickerSheet
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

    /// About — one tappable Version row that opens the **What's New** modal
    /// (`WhatsNewSheet`). Same pattern on every platform: the changelog
    /// highlights live in a sheet rather than expanding inline, so the section
    /// stays a single calm row no matter how long the list grows.
    private var aboutSection: some View {
        AetherSettingsSection("About") {
            Button {
                isWhatsNewPresented = true
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
                }
                .padding(AetherDesign.Spacing.m)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(viewModel.versionRowLabel). What's New.")
            .accessibilityHint("Opens what's new in this version")
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

/// The **What's New** modal opened from the About → Version row. A headline,
/// the version it covers, and the shipped highlights as a checked bullet list.
/// Mirrors `PreferencePickerSheet`'s container so the two modals feel identical.
private struct WhatsNewSheet: View {
    let version: String
    let codename: String
    let bullets: [String]
    let onClose: () -> Void

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
            }

            AetherButton("Done", role: .secondary, action: onClose)
                .padding(.horizontal, AetherDesign.Spacing.l)
                .padding(.bottom, AetherDesign.Spacing.l)
        }
        .background(AetherDesign.Palette.background.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private extension View {
    /// Apply `.focusSection()` on tvOS so the focus engine can move between the
    /// two dashboard columns; no-op elsewhere (the API is tvOS-only).
    @ViewBuilder
    func aetherFocusSection() -> some View {
        #if os(tvOS)
        self.focusSection()
        #else
        self
        #endif
    }
}
