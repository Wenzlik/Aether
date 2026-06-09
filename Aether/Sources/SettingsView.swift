import SwiftUI
import AetherCore
import UniformTypeIdentifiers

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
    @State private var isImportingLocal = false
    @State private var isRematching = false
    @State private var openPicker: PrefPicker?
    /// Device volume stats for the Storage Summary card. `nil` until the probe
    /// runs (and stays nil if it fails) — the free-space row just hides.
    @State private var deviceCapacity: DeviceCapacity?
    /// Current on-disk artwork cache size, shown next to "Clear Image Cache".
    @State private var imageCacheBytes: Int = 0
    #if os(iOS)
    /// Alternate app-icon chooser (iOS / iPadOS only).
    @State private var appIconStore = AppIconStore()
    #endif
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

    #if !os(tvOS)
    /// Which Support flow sheet is open. tvOS has no mail composer, so the whole
    /// Support section is compiled out there.
    private enum SupportSheet: String, Identifiable {
        case reportBug, featureRequest, contact, sendDiagnostics
        var id: String { rawValue }
    }
    @State private var supportSheet: SupportSheet?
    /// `mailto:` fallback when no Mail account is configured.
    @Environment(\.openURL) private var openURL
    #endif

    /// About / Diagnostics info sheets (all platforms).
    private enum InfoSheet: String, Identifiable {
        case about, diagnostics
        var id: String { rawValue }
    }
    @State private var infoSheet: InfoSheet?

    /// Which connected source's detail sheet is open. Tapping a compact Account
    /// row opens it; it holds the server, status, and the (rarely-used,
    /// previously always-exposed) Sign Out action.
    private enum AccountSheet: String, Identifiable {
        case plex, jellyfin
        var id: String { rawValue }
    }
    @State private var accountSheet: AccountSheet?

    /// Hidden developer mode, unlocked by tapping the wordmark in About.
    @AppStorage("developer.unlocked") private var developerUnlocked = false

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
                    .frame(maxWidth: .infinity, alignment: .center)
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
                bullets: viewModel.whatsNewBullets,
                history: viewModel.releaseHistory
            ) { isWhatsNewPresented = false }
        }
        .sheet(item: $infoSheet) { sheet in infoSheetView(for: sheet) }
        .sheet(item: $accountSheet) { sheet in accountSheetView(for: sheet) }
        #if !os(tvOS)
        .sheet(item: $supportSheet) { sheet in supportSheetView(for: sheet) }
        #endif
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
                leftColumnSections
            }
            .frame(maxWidth: .infinity, alignment: .top)
            // tvOS: mark each column a focus section so a Right/Left press jumps
            // between them.
            .aetherFocusSection()

            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                rightColumnSections
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .aetherFocusSection()
        }
    }

    /// iPhone: a single column — both groups stacked.
    private var compactColumn: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
            leftColumnSections
            rightColumnSections
        }
    }

    /// Left column (wide) — the "what to play / from where" configuration.
    @ViewBuilder
    private var leftColumnSections: some View {
        accountSection
        sourcesSection
        #if !os(tvOS)
        localLibrarySection
        downloadsSection
        #endif
        playbackSection
        #if os(visionOS)
        cinemaSection
        #endif
    }

    /// Right column (wide) — personalization, support/info, and the status +
    /// cache cards. (The redundant "Connected Sources" status card was removed —
    /// the Sources section already shows each source's connection state.)
    @ViewBuilder
    private var rightColumnSections: some View {
        appearanceSection
        #if os(iOS)
        appIconSection
        #endif
        #if !os(tvOS)
        supportSection
        #endif
        aboutSection
        if developerUnlocked {
            developerSection
        }
        #if !os(tvOS)
        storageSummaryCard
        #endif
        imageCacheCard
    }

    #if os(iOS)
    /// App Icon (iOS / iPadOS): pick the home-screen icon. Backed by the
    /// system's alternate-icon API (`AppIconStore`), which persists the choice.
    private var appIconSection: some View {
        AetherSettingsSection("App Icon") {
            if appIconStore.isSupported {
                HStack(spacing: AetherDesign.Spacing.m) {
                    Text("Choose how Aether appears on your Home Screen.")
                        .font(AetherDesign.Typography.metadata)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: AetherDesign.Spacing.s)
                    Picker(
                        "App Icon",
                        selection: Binding(
                            get: { appIconStore.current },
                            set: { appIconStore.select($0) }
                        )
                    ) {
                        ForEach(AetherAppIcon.allCases) { icon in
                            Text(icon.displayName).tag(icon)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(AetherDesign.Palette.accent)
                }
                .padding(AetherDesign.Spacing.m)
            } else {
                Text("Not available on this device.")
                    .font(AetherDesign.Typography.metadata)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
                    .padding(.horizontal, AetherDesign.Spacing.l)
                    .padding(.vertical, AetherDesign.Spacing.s)
            }
        }
    }
    #endif

    #if os(visionOS)
    /// Cinema (visionOS): the home for immersive-playback preferences — the
    /// default screen size + seat the theater opens with, the environment, and
    /// the auto-enter / remember-last behaviour. All persist via
    /// `CinemaPreferencesStore`; the size/seat can still be changed live in the
    /// docked player's Theater tab.
    private var cinemaSection: some View {
        AetherSettingsSection("Cinema") {
            cinemaMenuRow(
                "Default Screen Size",
                systemImage: "rectangle.expand.vertical",
                description: "The size Cinema Mode opens with. You can still resize during playback.",
                selection: Binding(
                    get: { viewModel.cinemaPreferences.defaultScreenPreset },
                    set: { viewModel.cinemaPreferences.defaultScreenPreset = $0 }
                ),
                options: CinemaScreenPreset.ordered,
                label: \.displayName
            )
            cinemaMenuRow(
                "Default Seating",
                systemImage: "chair.lounge.fill",
                description: "Where you sit when the theater opens.",
                selection: Binding(
                    get: { viewModel.cinemaPreferences.defaultSeat },
                    set: { viewModel.cinemaPreferences.defaultSeat = $0 }
                ),
                options: CinemaSeat.ordered,
                label: \.displayName
            )
            cinemaMenuRow(
                "Environment",
                systemImage: "theatermasks.fill",
                description: "The space rendered around the screen.",
                selection: Binding(
                    get: { viewModel.cinemaPreferences.environment },
                    set: { viewModel.cinemaPreferences.environment = $0 }
                ),
                options: CinemaEnvironment.available,
                label: \.displayName
            )
            cinemaToggleRow(
                "Auto-Enter Cinema",
                systemImage: "sparkles.tv.fill",
                description: "Enter Cinema Mode automatically when playback starts.",
                isOn: Binding(
                    get: { viewModel.cinemaPreferences.autoEnterCinema },
                    set: { viewModel.cinemaPreferences.autoEnterCinema = $0 }
                )
            )
            cinemaToggleRow(
                "Remember Last Setup",
                systemImage: "clock.arrow.circlepath",
                description: "Reopen with your last screen size and seat instead of the defaults.",
                isOn: Binding(
                    get: { viewModel.cinemaPreferences.rememberLastSetup },
                    set: { viewModel.cinemaPreferences.rememberLastSetup = $0 }
                )
            )
        }
    }

    /// A Cinema settings row: icon + title + muted description, trailing inline
    /// menu picker. Matches the frosted-card row rhythm without a chevron.
    @ViewBuilder
    private func cinemaMenuRow<T: Hashable>(
        _ title: String,
        systemImage: String,
        description: String? = nil,
        selection: Binding<T>,
        options: [T],
        label: @escaping (T) -> String
    ) -> some View {
        HStack(spacing: AetherDesign.Spacing.m) {
            cinemaRowLabel(title, systemImage: systemImage, description: description)
            Spacer(minLength: AetherDesign.Spacing.s)
            Picker(title, selection: selection) {
                ForEach(options, id: \.self) { Text(label($0)).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(AetherDesign.Palette.accent)
        }
        .padding(AetherDesign.Spacing.m)
    }

    /// A Cinema settings row with a trailing toggle.
    @ViewBuilder
    private func cinemaToggleRow(
        _ title: String,
        systemImage: String,
        description: String? = nil,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            cinemaRowLabel(title, systemImage: systemImage, description: description)
        }
        .tint(AetherDesign.Palette.accent)
        .padding(AetherDesign.Spacing.m)
    }

    @ViewBuilder
    private func cinemaRowLabel(_ title: String, systemImage: String, description: String?) -> some View {
        HStack(spacing: AetherDesign.Spacing.m) {
            Image(systemName: systemImage)
                .foregroundStyle(AetherDesign.Palette.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AetherDesign.Typography.body)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                if let description {
                    Text(description)
                        .font(AetherDesign.Typography.caption)
                        .foregroundStyle(AetherDesign.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
    #endif

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

    /// Read the volume Aether's downloads live on. Fails silently (capacity
    /// stays nil and the Free Space row just doesn't render).
    ///
    /// Uses `volumeAvailableCapacityForImportantUsage` — the realistic
    /// free space iOS reports in Settings — not `.systemFreeSize`, which
    /// reports only the much smaller space visible to the app's process
    /// (it was showing ~10 GB on a device with >100 GB free; #231).
    private func refreshCapacity() async {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey,
        ]),
              let free = values.volumeAvailableCapacityForImportantUsage,
              let total = values.volumeTotalCapacity else { return }
        deviceCapacity = DeviceCapacity(free: free, total: Int64(total))
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Sections

    /// Compact Account (§1/§2). On iOS / iPadOS / visionOS each connected service
    /// is one row that opens a detail sheet (status + Sign Out) — destructive
    /// actions no longer sit permanently on screen, and a healthy "Connected"
    /// badge is dropped. **tvOS uses an inline variant instead:** modal sheets are
    /// fiddly to focus with the Siri Remote (the sheet's Sign Out was unreachable),
    /// and there's room here, so Sign Out stays a directly-focusable row.
    @ViewBuilder
    private var accountSection: some View {
        #if os(tvOS)
        accountSectionInline
        #else
        accountSectionCompact
        #endif
    }

    private var accountSectionCompact: some View {
        AetherSettingsSection("Account") {
            if viewModel.isPlexSignedIn {
                AetherSettingsRow(
                    label: "Plex",
                    value: viewModel.connectedServerName ?? "Connected"
                ) { accountSheet = .plex }
            } else {
                AetherSettingsRow(label: "Plex", status: .notConnected) { viewModel.connect() }
            }

            if viewModel.isJellyfinSignedIn {
                AetherSettingsRow(
                    label: "Jellyfin",
                    value: viewModel.jellyfinServerName ?? "Connected"
                ) { accountSheet = .jellyfin }
            } else {
                AetherSettingsRow(label: "Jellyfin", status: .notConnected) { viewModel.connectJellyfin() }
            }
        }
    }

    #if os(tvOS)
    /// tvOS Account: server shown as a plain row, with Sign Out as its own
    /// directly-focusable destructive row (no sheet to get trapped behind).
    private var accountSectionInline: some View {
        AetherSettingsSection("Account") {
            if viewModel.isPlexSignedIn {
                AetherSettingsRow(label: "Plex", value: viewModel.connectedServerName ?? "Connected")
                AetherSettingsRow(
                    label: isSigningOut ? "Signing out…" : "Sign Out of Plex",
                    actionRole: .destructive
                ) { Task { await performSignOut() } }
                .disabled(isSigningOut)
            } else {
                AetherSettingsRow(label: "Plex", status: .notConnected) { viewModel.connect() }
            }

            if viewModel.isJellyfinSignedIn {
                AetherSettingsRow(label: "Jellyfin", value: viewModel.jellyfinServerName ?? "Connected")
                AetherSettingsRow(
                    label: isSigningOutJellyfin ? "Signing out…" : "Sign Out of Jellyfin",
                    actionRole: .destructive
                ) { Task { await performSignOutJellyfin() } }
                .disabled(isSigningOutJellyfin)
            } else {
                AetherSettingsRow(label: "Jellyfin", status: .notConnected) { viewModel.connectJellyfin() }
            }
        }
    }
    #endif

    /// Per-source detail sheet opened from the compact Account rows.
    @ViewBuilder
    private func accountSheetView(for sheet: AccountSheet) -> some View {
        switch sheet {
        case .plex:
            SourceAccountSheet(
                title: "Plex",
                serverName: viewModel.connectedServerName,
                status: .connected,
                isSigningOut: isSigningOut,
                onSignOut: { Task { await performSignOut(); accountSheet = nil } },
                onClose: { accountSheet = nil }
            )
        case .jellyfin:
            SourceAccountSheet(
                title: "Jellyfin",
                serverName: viewModel.jellyfinServerName,
                status: .connected,
                isSigningOut: isSigningOutJellyfin,
                onSignOut: { Task { await performSignOutJellyfin(); accountSheet = nil } },
                onClose: { accountSheet = nil }
            )
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
            status = viewModel.isActiveSource(kind) ? .neutral("Active") : .connected
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

    // MARK: - Local Library

    /// Import on-device media files (Files / document picker) to play without a
    /// server (#173). tvOS has no document picker, so it compiles out there.
    #if !os(tvOS)
    private var localLibrarySection: some View {
        AetherSettingsSection("Local Library") {
            AetherSettingsRow(
                label: "Import Media…",
                description: "Add video files from Files to play without a server.",
                systemImage: "square.and.arrow.down",
                value: nil
            ) {
                isImportingLocal = true
            }
            if viewModel.localItemCount > 0 {
                let n = viewModel.localItemCount
                AetherSettingsRow(label: "Imported", value: "\(n) item\(n == 1 ? "" : "s")")
                if viewModel.isTMDbConfigured {
                    AetherSettingsRow(
                        label: isRematching ? "Matching…" : "Re-match Metadata",
                        description: "Fetch posters & details for titles imported before a key was set.",
                        systemImage: "arrow.clockwise",
                        value: nil
                    ) {
                        guard !isRematching else { return }
                        isRematching = true
                        Task { await viewModel.rematchLocalMetadata(); isRematching = false }
                    }
                    .disabled(isRematching)
                }
            }
        }
        .fileImporter(
            isPresented: $isImportingLocal,
            allowedContentTypes: localImportTypes,
            allowsMultipleSelection: true
        ) { result in
            guard case let .success(urls) = result, !urls.isEmpty else { return }
            Task { await viewModel.importLocalMedia(urls) }
        }
    }

    /// Video UTTypes the picker accepts, plus dynamic types for containers
    /// without a built-in UTI (mkv / avi / ts) so they're still selectable.
    private var localImportTypes: [UTType] {
        var types: [UTType] = [.movie, .video, .audiovisualContent, .mpeg4Movie, .quickTimeMovie]
        for ext in ["mkv", "avi", "ts", "m2ts", "webm"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }
    #endif

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
        // Icons dropped from these rows (§4): the "PLAYBACK" section title already
        // gives context, and an icon on every value row read as an admin panel.
        AetherSettingsSection("Playback") {
            AetherDisclosureRow(
                label: "Default Quality",
                value: viewModel.playbackPreferences.defaultQuality.displayName
            ) {
                openPicker = .quality
            }
            AetherDisclosureRow(
                label: "Audio Language",
                value: languageLabel(viewModel.playbackPreferences.defaultAudioLanguage)
            ) {
                openPicker = .audio
            }
            AetherDisclosureRow(
                label: "Subtitle Language",
                value: subtitleLabel(viewModel.playbackPreferences.defaultSubtitleLanguage)
            ) {
                openPicker = .subtitles
            }
            AetherDisclosureRow(
                label: "Skip Intro",
                value: viewModel.playbackPreferences.skipIntro.displayName
            ) {
                openPicker = .skipIntro
            }
            AetherDisclosureRow(
                label: "Skip Credits",
                value: viewModel.playbackPreferences.skipCredits.displayName
            ) {
                openPicker = .skipCredits
            }
            AetherDisclosureRow(
                label: "Auto-Play Next Episode",
                value: viewModel.playbackPreferences.autoPlayNext ? "On" : "Off"
            ) {
                openPicker = .autoPlayNext
            }
            AetherDisclosureRow(
                label: "Next Episode Countdown",
                value: "\(viewModel.playbackPreferences.nextEpisodeCountdown)s"
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
                description: "Match the system, or force Dark or Light.",
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

    #if !os(tvOS)
    /// Support — Report a Bug / Feature Request / Contact the Creator. Each opens
    /// the system Mail composer to `aether@zmrhal.cz` (with a `mailto:` fallback
    /// when no mail account is configured). Compiled out on tvOS (no MessageUI).
    private var supportSection: some View {
        AetherSettingsSection("Support") {
            AetherSettingsRow(label: "Report a Bug", description: "Something not working? Your build and device are attached automatically.", systemImage: "ladybug.fill", value: nil) {
                supportSheet = .reportBug
            }
            AetherSettingsRow(label: "Feature Request", description: "Suggest an idea for a future version.", systemImage: "lightbulb.fill", value: nil) {
                supportSheet = .featureRequest
            }
            AetherSettingsRow(label: "Send Diagnostics", description: "Email a readable report of app state — no account details.", systemImage: "stethoscope", value: nil) {
                supportSheet = .sendDiagnostics
            }
            AetherSettingsRow(label: "Contact the Creator", description: "Get in touch with the person behind Aether.", systemImage: "envelope.fill", value: nil) {
                contactDeveloper()
            }
            AetherSettingsRow(label: "What's New", description: "Release notes for this and past versions.", systemImage: "sparkles", value: viewModel.versionString) {
                isWhatsNewPresented = true
            }
        }
    }

    @ViewBuilder
    private func supportSheetView(for sheet: SupportSheet) -> some View {
        switch sheet {
        case .reportBug:
            ReportBugSheet(theme: viewModel.appearance.preference.displayName) { supportSheet = nil }
        case .featureRequest:
            FeatureRequestSheet { supportSheet = nil }
        case .sendDiagnostics:
            SendDiagnosticsSheet(gather: { await viewModel.gatherDiagnostics() }) { supportSheet = nil }
        case .contact:
            MailComposeView(
                recipient: SupportDiagnostics.supportEmail,
                subject: "Aether — Hello",
                body: "\n\n\(SupportDiagnostics.featureRequestFooter())",
                attachment: nil
            ) { supportSheet = nil }
            .ignoresSafeArea()
        }
    }

    /// Contact the developer: present the Mail composer, or fall back to a
    /// `mailto:` link when the device has no Mail account.
    private func contactDeveloper() {
        if MailComposeView.canSend {
            supportSheet = .contact
        } else if let url = aetherMailtoURL(
            recipient: SupportDiagnostics.supportEmail,
            subject: "Aether — Hello",
            body: "\n\n\(SupportDiagnostics.featureRequestFooter())"
        ) {
            openURL(url)
        }
    }
    #endif

    /// About — one tappable Version row that opens the **What's New** modal
    /// (`WhatsNewSheet`). Same pattern on every platform: the changelog
    /// highlights live in a sheet rather than expanding inline, so the section
    /// stays a single calm row no matter how long the list grows.
    private var aboutSection: some View {
        AetherSettingsSection("About") {
            AetherSettingsRow(label: "About Aether", description: "What Aether is, who made it, and where it's going.", systemImage: "sparkles", value: nil) {
                infoSheet = .about
            }
            // Diagnostics lives in Support → Send Diagnostics everywhere it can.
            // tvOS has no MessageUI (the whole Support section is compiled out),
            // so keep an in-app Diagnostics view here as tvOS's only access.
            #if os(tvOS)
            AetherSettingsRow(label: "Diagnostics", description: "A readable snapshot of sources, library, downloads, and cache.", systemImage: "waveform.path.ecg", value: nil) {
                infoSheet = .diagnostics
            }
            #endif
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

    @ViewBuilder
    private func infoSheetView(for sheet: InfoSheet) -> some View {
        switch sheet {
        case .about:
            AboutView(versionLabel: viewModel.versionRowLabel) { infoSheet = nil }
        case .diagnostics:
            DiagnosticsView(gather: { await viewModel.gatherDiagnostics() }) { infoSheet = nil }
        }
    }

    /// Hidden developer mode (unlocked by tapping the wordmark in About). Internal
    /// build / device / cache facts — not a polished surface, just the details.
    private var developerSection: some View {
        AetherSettingsSection("Developer") {
            AetherSettingsRow(label: "Version", value: viewModel.versionString)
            AetherSettingsRow(label: "Build", value: viewModel.buildString)
            if let commit = viewModel.commitString {
                AetherSettingsRow(label: "Commit", value: commit)
            }
            AetherSettingsRow(label: "Platform", value: SupportDiagnostics.platformName)
            AetherSettingsRow(label: "Device", value: SupportDiagnostics.deviceModel())
            AetherSettingsRow(label: "OS", value: SupportDiagnostics.osVersion)
            AetherSettingsRow(label: "Image Cache", value: formatBytes(Int64(imageCacheBytes)))
            AetherSettingsRow(label: "Lock Developer Mode", actionRole: .destructive) {
                developerUnlocked = false
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
        .aetherScreenBackground()
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
              VStack(alignment: .leading, spacing: 0) {   // tvOS: one focusable scroll body
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
              }
              .tvOSScrollFocusable()
            }

            AetherButton("Done", role: .secondary, action: onClose)
                .padding(.horizontal, AetherDesign.Spacing.l)
                .padding(.bottom, AetherDesign.Spacing.l)
        }
        .aetherScreenBackground()
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
