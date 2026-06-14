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
    /// Owned by `RootTabView` so re-tapping the Settings tab pops to the index
    /// (#300) — global nav resets to the section root, not "restore deep state".
    @Binding var navigationPath: NavigationPath

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
    /// Gate the (destructive) cache clear behind a confirmation — it used to wipe
    /// on a single tap, which was easy to hit by accident.
    @State private var showClearCacheConfirm = false
    /// "119 / 417" matched, once the SMB library has been browsed this session.
    @State private var smbMatchSummary: String?
    /// SMB details (account, match count, downloads, actions) tuck under an
    /// expandable row so the Account section stays calm; expanded by tap.
    @State private var smbExpanded = false
    /// Presents the TMDb token editor (#214 — user fallback / override).
    @State private var isEditingTMDbToken = false
    /// Presents the Plex server picker — switch servers when the account can
    /// reach more than one (#323). Opened from the Plex account sheet.
    @State private var isPickingPlexServer = false
    /// Presents the SMB folder picker for the *connected* share (add/remove
    /// folders after sign-in, #214), seeded with the current roots.
    @State private var isEditingSMBFolders = false
    @State private var smbEditRoots: [String] = []
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
        case quality, audio, subtitles, appearance, language, skipIntro, skipCredits, autoPlayNext, countdown, watchedDimming, watchedLabelOpacity
        #if os(iOS)
        case appIcon
        #endif
        #if os(visionOS)
        case cinemaScreen, cinemaSeat, cinemaEnvironment
        #endif
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
        NavigationStack(path: $navigationPath) {
            ZStack {
                AetherDesign.Gradients.background.ignoresSafeArea()

                // Drive content width off the *measured* viewport so it can never
                // be proposed wider than the screen. A fixed `maxWidth: 1100`
                // proposed 1100pt to the width-greedy cards even when the viewport
                // was narrower (iPad portrait / split view), so the two columns
                // laid out past the edges and centered off-screen — both columns
                // clipped (#287, same root cause as the old #248 pannability).
                // `min(viewport − margins, 1100)`, centered, fits + keeps margins.
                GeometryReader { geo in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                            header
                            settingsIndex
                        }
                        .padding(.top, AetherDesign.Spacing.l)
                        .padding(.bottom, AetherDesign.Spacing.xxl)
                        .frame(width: settingsContentWidth(geo.size.width))
                        .frame(maxWidth: .infinity)
                    }
                    .task {
                        await refreshCapacity()
                        imageCacheBytes = await Task.detached { AetherImageCache.shared.diskUsageBytes() }.value
                    }
                }
            }
            // The root Settings surface carries its own wordmark, so suppress the
            // empty navigation bar; pushed screens (Downloads) show their own.
            #if os(iOS) || os(visionOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .navigationDestination(for: SettingsCategory.self) { category in
                categoryScreen(category)
            }
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
        .sheet(isPresented: $isEditingTMDbToken) {
            TMDbTokenEditSheet(
                initialToken: viewModel.userTMDbToken,
                hasBuiltInKey: viewModel.hasBuiltInTMDbKey,
                validate: { await viewModel.validateTMDbToken($0) },
                onSave: { await viewModel.setTMDbToken($0) }
            )
        }
        .sheet(isPresented: $isEditingSMBFolders, onDismiss: {
            // Persist the edited folder set on dismiss (no-op if unchanged).
            Task { await viewModel.updateSMBRoots(smbEditRoots) }
        }) {
            if let connection = viewModel.smbConnection {
                SMBFolderPickerView(connection: connection, selectedRoots: $smbEditRoots)
            }
        }
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

    // MARK: - Index (#289)

    /// Top-level Settings is a calm **index** of categories — each opens its own
    /// focused screen — instead of one dense dashboard that competed for space
    /// and clipped on iPad (#287/#289). Each category screen reuses the existing
    /// section builders, so behaviour is unchanged; only the navigation is.
    private enum SettingsCategory: String, CaseIterable, Identifiable, Hashable {
        case accountsSources, playback, libraryDownloads, appearance, supportAbout
        var id: String { rawValue }
        var title: String {
            switch self {
            case .accountsSources: return "Accounts & Sources"
            case .playback: return "Playback"
            case .libraryDownloads: return "Library & Downloads"
            case .appearance: return "Appearance"
            case .supportAbout: return "Support & About"
            }
        }
        var subtitle: String {
            switch self {
            case .accountsSources: return "Plex, Jellyfin, SMB, and local files"
            case .playback: return "Quality, audio & subtitles, skip"
            case .libraryDownloads: return "Downloads, storage, and cache"
            case .appearance: return "Theme, app icon, and watched titles"
            case .supportAbout: return "Report a bug, diagnostics, about"
            }
        }
        var systemImage: String {
            switch self {
            case .accountsSources: return "person.2.circle.fill"
            case .playback: return "play.circle.fill"
            case .libraryDownloads: return "arrow.down.circle.fill"
            case .appearance: return "paintbrush.fill"
            case .supportAbout: return "questionmark.circle.fill"
            }
        }
    }

    private var settingsIndex: some View {
        VStack(spacing: AetherDesign.Spacing.m) {
            ForEach(SettingsCategory.allCases) { category in
                NavigationLink(value: category) {
                    HStack(spacing: AetherDesign.Spacing.m) {
                        Image(systemName: category.systemImage)
                            .font(.title3)
                            .foregroundStyle(AetherDesign.Palette.accent)
                            .frame(width: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(LocalizedStringKey(category.title))
                                .font(AetherDesign.Typography.cardTitle)
                                .foregroundStyle(AetherDesign.Palette.textPrimary)
                            Text(LocalizedStringKey(category.subtitle))
                                .font(AetherDesign.Typography.caption)
                                .foregroundStyle(AetherDesign.Palette.textTertiary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AetherDesign.Palette.textTertiary)
                    }
                    .padding(AetherDesign.Spacing.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                            .fill(AetherDesign.Palette.surface)
                    )
                    .premiumFocus()
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// One category's own screen — a single-column scroll of the relevant
    /// existing sections (no two-column dashboard, which is what clipped on
    /// iPad). Pushed onto the Settings `NavigationStack`.
    @ViewBuilder
    private func categoryScreen(_ category: SettingsCategory) -> some View {
        ZStack {
            AetherDesign.Gradients.background.ignoresSafeArea()
            GeometryReader { geo in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                        categorySections(category)
                    }
                    .padding(.top, AetherDesign.Spacing.l)
                    .padding(.bottom, AetherDesign.Spacing.xxl)
                    .frame(width: settingsContentWidth(geo.size.width))
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle(LocalizedStringKey(category.title))
        #if os(iOS)
        // Inline (centered) on every category screen — consistent and reliable.
        // Large titles collapsed unpredictably inside the GeometryReader+ScrollView
        // nesting (one screen showed large, another inline).
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    private func categorySections(_ category: SettingsCategory) -> some View {
        switch category {
        case .accountsSources:
            accountSection
            metadataSection
            #if !os(tvOS)
            localLibrarySection
            #endif
        case .playback:
            playbackSection
            #if os(visionOS)
            cinemaSection
            #endif
        case .libraryDownloads:
            #if !os(tvOS)
            downloadsSection
            storageSummaryCard
            #endif
            imageCacheCard
        case .appearance:
            appearanceSection
            watchedDisplaySection
        case .supportAbout:
            #if !os(tvOS)
            supportSection
            #endif
            aboutSection
            if developerUnlocked {
                developerSection
            }
        }
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

    /// Content width for the settings scroll body: the viewport minus side
    /// margins, capped at 1100 on roomy surfaces. Computed from the *measured*
    /// viewport (not a fixed `maxWidth`) so the width-greedy cards are never
    /// proposed more than the screen — which previously pushed the two-column
    /// iPad layout past both edges (#287). The fallback keeps a sane width during
    /// the GeometryReader's first (zero-size) layout pass so nothing blanks.
    private func settingsContentWidth(_ viewport: CGFloat) -> CGFloat {
        guard viewport > 0 else { return 320 }
        let available = viewport - AetherDesign.Spacing.l * 2
        return isWide ? min(available, 1100) : available
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
    /// cache cards. (Connection state lives on the Account rows; the separate
    /// "Connected Sources" card and the Sources section were both removed as
    /// duplicates of Account — #224.)
    @ViewBuilder
    private var rightColumnSections: some View {
        appearanceSection
        watchedDisplaySection
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

    #if os(visionOS)
    /// Cinema (visionOS): the home for immersive-playback preferences — the
    /// default screen size + seat the theater opens with, the environment, and
    /// the auto-enter / remember-last behaviour. All persist via
    /// `CinemaPreferencesStore`; the size/seat can still be changed live in the
    /// docked player's Theater tab.
    private var cinemaSection: some View {
        AetherSettingsSection("Cinema") {
            // Same disclosure → sheet picker pattern as Theme / Playback (no
            // inline menus, no per-row icons), for one consistent settings style.
            AetherDisclosureRow(
                label: "Default Screen Size",
                description: "The size Cinema Mode opens with. You can still resize during playback.",
                value: viewModel.cinemaPreferences.defaultScreenPreset.displayName
            ) { openPicker = .cinemaScreen }
            AetherDisclosureRow(
                label: "Default Seating",
                description: "Where you sit when the theater opens.",
                value: viewModel.cinemaPreferences.defaultSeat.displayName
            ) { openPicker = .cinemaSeat }
            AetherDisclosureRow(
                label: "Environment",
                description: "The space rendered around the screen.",
                value: viewModel.cinemaPreferences.environment.displayName
            ) { openPicker = .cinemaEnvironment }
            settingsToggle(
                "Auto-Enter Cinema",
                description: "Enter Cinema Mode automatically when playback starts.",
                isOn: Binding(
                    get: { viewModel.cinemaPreferences.autoEnterCinema },
                    set: { viewModel.cinemaPreferences.autoEnterCinema = $0 }
                )
            )
            settingsToggle(
                "Remember Last Setup",
                description: "Reopen with your last screen size and seat instead of the defaults.",
                isOn: Binding(
                    get: { viewModel.cinemaPreferences.rememberLastSetup },
                    set: { viewModel.cinemaPreferences.rememberLastSetup = $0 }
                )
            )
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
                description: "Posters & artwork cached on this device (Plex, SMB, local). Tap to review the size before clearing.",
                value: formatBytes(Int64(imageCacheBytes))
            ) {
                // Re-measure, then confirm — never a one-tap wipe (#cache).
                Task {
                    imageCacheBytes = await Task.detached { AetherImageCache.shared.diskUsageBytes() }.value
                    showClearCacheConfirm = true
                }
            }
        }
        .confirmationDialog(
            "Clear \(formatBytes(Int64(imageCacheBytes))) of cached artwork?",
            isPresented: $showClearCacheConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear Image Cache", role: .destructive) {
                AetherImageCache.shared.clear()
                imageCacheBytes = 0
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Posters re-download as you browse. No media is deleted.")
        }
    }


    #if !os(tvOS)
    /// Device-level storage at a glance: how much Aether's downloads use, and
    /// how much room is left on the volume.
    private var storageSummaryCard: some View {
        AetherSettingsSection("Storage Summary") {
            AetherSettingsRow(
                label: "Downloads",
                value: formatBytes(totalDownloadBytes)
            )
            if let capacity = deviceCapacity {
                AetherSettingsRow(
                    label: "Free Space",
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
        #if os(tvOS)
        // volumeAvailableCapacityForImportantUsage is unavailable on tvOS; use
        // the plain available-capacity key (the Storage card is iOS/visionOS-only
        // anyway, so this just keeps the shared helper compiling).
        guard let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityKey,
            .volumeTotalCapacityKey,
        ]),
              let free = values.volumeAvailableCapacity,
              let total = values.volumeTotalCapacity else { return }
        deviceCapacity = DeviceCapacity(free: Int64(free), total: Int64(total))
        #else
        guard let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey,
        ]),
              let free = values.volumeAvailableCapacityForImportantUsage,
              let total = values.volumeTotalCapacity else { return }
        deviceCapacity = DeviceCapacity(free: free, total: Int64(total))
        #endif
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        return formatter.string(fromByteCount: bytes)
    }

    /// The single toggle-row style across Settings: label + optional muted
    /// description.
    ///
    /// iOS / visionOS use a native `Toggle` (a tidy trailing switch). tvOS does
    /// NOT — its default `Toggle` renders as a heavy full-width blue "On" pill
    /// that clashes with the disclosure rows beside it (#310). There it's a
    /// focusable row showing "On" / "Off" on the right, flipping on select —
    /// visually matching Theme / Watched Dimming / Label Opacity.
    @ViewBuilder
    private func settingsToggle(_ title: String, description: String? = nil, isOn: Binding<Bool>) -> some View {
        #if os(tvOS)
        Button { isOn.wrappedValue.toggle() } label: {
            HStack(spacing: AetherDesign.Spacing.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(title))
                        .font(AetherDesign.Typography.body)
                        .foregroundStyle(AetherDesign.Palette.textPrimary)
                    if let description {
                        Text(LocalizedStringKey(description))
                            .font(AetherDesign.Typography.caption)
                            .foregroundStyle(AetherDesign.Palette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: AetherDesign.Spacing.s)
                Text(isOn.wrappedValue ? "On" : "Off")
                    .font(AetherDesign.Typography.metadata)
                    .foregroundStyle(isOn.wrappedValue ? AetherDesign.Palette.accent : AetherDesign.Palette.textSecondary)
            }
            .padding(AetherDesign.Spacing.m)
            .contentShape(Rectangle())
            .aetherFocusRow()
        }
        .buttonStyle(.plain)
        #else
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title))
                    .font(AetherDesign.Typography.body)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                if let description {
                    Text(LocalizedStringKey(description))
                        .font(AetherDesign.Typography.caption)
                        .foregroundStyle(AetherDesign.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(AetherDesign.Palette.accent)
        .padding(AetherDesign.Spacing.m)
        #endif
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
        Group {
            #if os(tvOS)
            accountSectionInline
            #else
            accountSectionCompact
            #endif
        }
        .task { await loadSMBMatchSummary() }
    }

    private func loadSMBMatchSummary() async {
        guard viewModel.isSMBConnected, let stats = await viewModel.smbMatchSummary() else {
            smbMatchSummary = nil
            return
        }
        smbMatchSummary = "\(stats.matched) / \(stats.total)"
    }

    // MARK: - SMB disclosure (#214 settings)

    /// Connected-SMB block: a tappable header that expands to show the account,
    /// match/download stats, and actions — so the Account section stays calm and
    /// SMB's detail is one tap away. tvOS-safe: a focusable header row + plain
    /// focusable rows (no `DisclosureGroup`, which mis-handles tvOS focus).
    @ViewBuilder
    private var smbDisclosure: some View {
        smbDisclosureHeader
        if smbExpanded {
            AetherSettingsRow(label: "Account", value: viewModel.smbUsername ?? "Guest")
            if let host = viewModel.smbHost {
                AetherSettingsRow(label: "Host", value: host)
            }
            AetherSettingsRow(label: "Folders", value: smbFoldersValue) {
                smbEditRoots = viewModel.smbConnection?.roots ?? []
                isEditingSMBFolders = true
            }
            AetherSettingsRow(label: "Posters Matched", value: smbMatchSummary ?? "Open Library to match")
            #if !os(tvOS)
            AetherSettingsRow(label: "Downloaded", value: smbDownloadedValue)
            #endif
            AetherSettingsRow(label: isRematching ? "Re-matching…" : "Re-match Posters", actionRole: .primary) {
                Task {
                    isRematching = true
                    await viewModel.refreshSMB()
                    await loadSMBMatchSummary()
                    isRematching = false
                }
            }
            .disabled(isRematching)
            AetherSettingsRow(label: "Disconnect SMB", actionRole: .destructive) {
                Task { await viewModel.signOutOfSMB() }
            }
        }
    }

    /// The expand/collapse header — server name + matched count subtitle, a
    /// chevron that rotates with state. Styled like an `AetherSettingsRow` so it
    /// sits flush in the section, and uses the shared tvOS focus lift.
    private var smbDisclosureHeader: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { smbExpanded.toggle() }
        } label: {
            HStack(spacing: AetherDesign.Spacing.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SMB")
                        .font(AetherDesign.Typography.body)
                        .foregroundStyle(AetherDesign.Palette.textPrimary)
                    if !viewModel.isSMBReachable {
                        Text("Off network — reconnects automatically when you're home")
                            .font(AetherDesign.Typography.caption)
                            .foregroundStyle(AetherDesign.Palette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let summary = smbMatchSummary {
                        Text("\(summary) matched")
                            .font(AetherDesign.Typography.caption)
                            .foregroundStyle(AetherDesign.Palette.textTertiary)
                    }
                }
                Spacer(minLength: AetherDesign.Spacing.s)
                Text(viewModel.isSMBReachable ? (viewModel.smbServerName ?? "Connected") : "Dormant")
                    .font(AetherDesign.Typography.metadata)
                    .foregroundStyle(AetherDesign.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
                    .rotationEffect(.degrees(smbExpanded ? 90 : 0))
            }
            .padding(.vertical, AetherDesign.Spacing.m)
            .padding(.horizontal, AetherDesign.Spacing.m)
            .contentShape(Rectangle())
            .aetherFocusRow()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("SMB details")
        .accessibilityValue(smbExpanded ? "Expanded" : "Collapsed")
    }

    private var smbFoldersValue: String {
        let count = viewModel.smbFolderCount
        if count == 0 { return "All shares" }
        return "\(count) folder\(count == 1 ? "" : "s")"
    }

    // MARK: - Metadata (TMDb token, #214)

    /// Lets the user supply their own TMDb token — used instead of the built-in
    /// key for poster/detail matching (SMB + Local). Backs the library-poster
    /// fallback the user asked for.
    private var metadataSection: some View {
        AetherSettingsSection("Metadata") {
            AetherSettingsRow(
                label: "TMDb Token",
                description: "Matches posters & details for SMB and local files. Add your own key if matching isn't working.",
                value: tmdbTokenStatus
            ) { isEditingTMDbToken = true }
        }
    }

    /// "Custom" when the user set a token, else "Built-in" / "Not set".
    private var tmdbTokenStatus: String {
        if !viewModel.userTMDbToken.isEmpty { return "Custom" }
        return viewModel.hasBuiltInTMDbKey ? "Built-in" : "Not set"
    }

    #if !os(tvOS)
    /// Count + total size of completed SMB downloads, from the live snapshot.
    private var smbDownloadedValue: String {
        guard let snapshot = downloads?.snapshot else { return "None" }
        var count = 0
        var bytes: Int64 = 0
        for job in snapshot.completed {
            guard case .smb = job.mediaID.source else { continue }
            count += 1
            if case let .completed(_, sizeBytes) = snapshot.status(for: job.mediaID) { bytes += sizeBytes }
        }
        guard count > 0 else { return "None" }
        return "\(count) file\(count == 1 ? "" : "s") · \(formatBytes(bytes))"
    }
    #endif

    private var accountSectionCompact: some View {
        AetherSettingsSection("Account") {
            if viewModel.isPlexSignedIn {
                AetherSettingsRow(
                    label: "Plex",
                    value: accountRowValue(.plex, serverName: viewModel.connectedServerName)
                ) { accountSheet = .plex }
            } else {
                AetherSettingsRow(label: "Plex", status: .notConnected) { viewModel.connect() }
            }

            if viewModel.isJellyfinSignedIn {
                AetherSettingsRow(
                    label: "Jellyfin",
                    value: accountRowValue(.jellyfin, serverName: viewModel.jellyfinServerName)
                ) { accountSheet = .jellyfin }
            } else {
                AetherSettingsRow(label: "Jellyfin", status: .notConnected) { viewModel.connectJellyfin() }
            }

            if viewModel.isSMBConnected {
                smbDisclosure
            } else {
                AetherSettingsRow(label: "SMB", status: .notConnected) { viewModel.connectSMB() }
            }
        }
    }

    #if os(tvOS)
    /// tvOS Account: server shown as a plain row, with Sign Out as its own
    /// directly-focusable destructive row (no sheet to get trapped behind).
    private var accountSectionInline: some View {
        AetherSettingsSection("Account") {
            if viewModel.isPlexSignedIn {
                AetherSettingsRow(label: "Plex", value: accountRowValue(.plex, serverName: viewModel.connectedServerName))
                if viewModel.canSwitchSources && !viewModel.isActiveSource(.plex) {
                    AetherSettingsRow(label: "Set Plex as Active Source", actionRole: .primary) { viewModel.setActive(.plex) }
                }
                AetherSettingsRow(
                    label: isSigningOut ? "Signing out…" : "Sign Out of Plex",
                    actionRole: .destructive
                ) { Task { await performSignOut() } }
                .disabled(isSigningOut)
            } else {
                AetherSettingsRow(label: "Plex", status: .notConnected) { viewModel.connect() }
            }

            if viewModel.isJellyfinSignedIn {
                AetherSettingsRow(label: "Jellyfin", value: accountRowValue(.jellyfin, serverName: viewModel.jellyfinServerName))
                if viewModel.canSwitchSources && !viewModel.isActiveSource(.jellyfin) {
                    AetherSettingsRow(label: "Set Jellyfin as Active Source", actionRole: .primary) { viewModel.setActive(.jellyfin) }
                }
                AetherSettingsRow(
                    label: isSigningOutJellyfin ? "Signing out…" : "Sign Out of Jellyfin",
                    actionRole: .destructive
                ) { Task { await performSignOutJellyfin() } }
                .disabled(isSigningOutJellyfin)
            } else {
                AetherSettingsRow(label: "Jellyfin", status: .notConnected) { viewModel.connectJellyfin() }
            }

            if viewModel.isSMBConnected {
                smbDisclosure
            } else {
                AetherSettingsRow(label: "SMB", status: .notConnected) { viewModel.connectSMB() }
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
                serverName: viewModel.plexServerSummary,
                status: (viewModel.canSwitchSources && viewModel.isActiveSource(.plex)) ? .neutral("Active") : .connected,
                canSetActive: viewModel.canSwitchSources && !viewModel.isActiveSource(.plex),
                isSigningOut: isSigningOut,
                onSetActive: { viewModel.setActive(.plex); accountSheet = nil },
                // Present the server picker *on top* of this sheet (#325), so
                // toggling returns here with the updated server set. Stacking on
                // the account sheet is more reliable than swapping two sheets
                // that share the Settings anchor.
                onChooseServer: { isPickingPlexServer = true },
                onSignOut: { Task { await performSignOut(); accountSheet = nil } },
                onClose: { accountSheet = nil }
            )
            .sheet(isPresented: $isPickingPlexServer) {
                PlexServerPickerSheet(
                    enabledIDs: viewModel.enabledPlexServerIDs,
                    load: { await viewModel.availablePlexServers() },
                    onToggle: { await viewModel.setPlexServerEnabled($0, enabled: $1) }
                )
            }
        case .jellyfin:
            SourceAccountSheet(
                title: "Jellyfin",
                serverName: viewModel.jellyfinServerName,
                status: (viewModel.canSwitchSources && viewModel.isActiveSource(.jellyfin)) ? .neutral("Active") : .connected,
                canSetActive: viewModel.canSwitchSources && !viewModel.isActiveSource(.jellyfin),
                isSigningOut: isSigningOutJellyfin,
                onSetActive: { viewModel.setActive(.jellyfin); accountSheet = nil },
                onSignOut: { Task { await performSignOutJellyfin(); accountSheet = nil } },
                onClose: { accountSheet = nil }
            )
        }
    }

    /// Trailing text for a connected Account row: the server name, with "· Active"
    /// appended for the source the Library is currently browsing — but only when
    /// more than one source is connected, so the tag actually distinguishes them.
    /// (The standalone Sources section was removed; its active-source switch now
    /// lives in each source's account sheet — #224.)
    private func accountRowValue(_ kind: AppSession.SourceKind, serverName: String?) -> String {
        let base = serverName ?? "Connected"
        guard viewModel.canSwitchSources, viewModel.isActiveSource(kind) else { return base }
        return "\(base) · Active"
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
            // A plain on/off — an inline toggle reads better than a sheet with
            // two radio options.
            settingsToggle("Auto-Play Next Episode", isOn: Binding(
                get: { viewModel.playbackPreferences.autoPlayNext },
                set: { viewModel.playbackPreferences.autoPlayNext = $0 }
            ))

            AetherDisclosureRow(
                label: "Next Episode Countdown",
                value: "\(viewModel.playbackPreferences.nextEpisodeCountdown)s"
            ) {
                openPicker = .countdown
            }
        }
    }

    // MARK: - Watched (Interface)

    /// How finished titles are presented — these are display/interface settings,
    /// not playback, so they live under Interface (grouped together rather than
    /// scattered through Playback).
    private var watchedDisplaySection: some View {
        AetherSettingsSection("Watched") {
            settingsToggle(
                "Hide Watched in Home & Discover",
                description: "Finished titles stay in your Library but leave the discovery rails.",
                isOn: Binding(
                    get: { viewModel.playbackPreferences.hideWatchedInDiscovery },
                    set: { viewModel.playbackPreferences.hideWatchedInDiscovery = $0 }
                )
            )

            AetherDisclosureRow(
                label: "Watched Dimming",
                value: viewModel.playbackPreferences.watchedDimming.displayName
            ) {
                openPicker = .watchedDimming
            }
            settingsToggle(
                "Show “Watched” Label",
                description: "A bold WATCHED tag over finished posters, on top of the dimming.",
                isOn: Binding(
                    get: { viewModel.playbackPreferences.watchedShowLabel },
                    set: { viewModel.playbackPreferences.watchedShowLabel = $0 }
                )
            )

            // Opacity only matters while the label is shown.
            if viewModel.playbackPreferences.watchedShowLabel {
                watchedLabelOpacityControl
            }
        }
    }

    /// Label-opacity control: a Transparent↔Solid slider on iOS / visionOS; a
    /// preset picker on tvOS (no `Slider` there). Both write the same Double.
    @ViewBuilder
    private var watchedLabelOpacityControl: some View {
        #if os(tvOS)
        AetherDisclosureRow(
            label: "Label Opacity",
            value: "\(Int((viewModel.playbackPreferences.watchedLabelOpacity * 100).rounded()))%"
        ) {
            openPicker = .watchedLabelOpacity
        }
        #else
        let opacityBinding = Binding(
            get: { viewModel.playbackPreferences.watchedLabelOpacity },
            // Clamp here (the store no longer self-clamps in didSet — that
            // recursed under @Observable and crashed the slider).
            set: { viewModel.playbackPreferences.watchedLabelOpacity = min(1.0, max(PlaybackPreferencesStore.minLabelOpacity, $0)) }
        )
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.s) {
            HStack {
                Text("Label Opacity")
                    .font(AetherDesign.Typography.body)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                Spacer()
                // Live preview of the wordmark at the current opacity.
                Text("WATCHED")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(1)
                    .foregroundStyle(.white.opacity(viewModel.playbackPreferences.watchedLabelOpacity))
                    .shadow(color: .black.opacity(0.75), radius: 3, y: 1)
                    .padding(.horizontal, AetherDesign.Spacing.s)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.35), in: Capsule())
            }
            HStack(spacing: AetherDesign.Spacing.s) {
                Text("Transparent")
                    .font(AetherDesign.Typography.caption)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
                Slider(value: opacityBinding, in: PlaybackPreferencesStore.minLabelOpacity...1.0)
                    .tint(AetherDesign.Palette.accent)
                Text("Solid")
                    .font(AetherDesign.Typography.caption)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
            }
        }
        .padding(AetherDesign.Spacing.m)
        #endif
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
                label: "Language",
                description: "Follow the device language, or pick one for Aether.",
                value: viewModel.language.preference.displayName
            ) {
                openPicker = .language
            }
            AetherDisclosureRow(
                label: "Theme",
                description: "Match the system, or force Dark or Light.",
                value: viewModel.appearance.preference.displayName
            ) {
                openPicker = .appearance
            }
            #if os(iOS)
            // App Icon is just another picker row here (no separate section) —
            // same disclosure → sheet pattern as Theme, for consistency.
            if appIconStore.isSupported {
                AetherDisclosureRow(
                    label: "App Icon",
                    value: appIconStore.current.displayName
                ) {
                    openPicker = .appIcon
                }
            }
            #endif
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
        case .language:       languagePickerSheet
        case .skipIntro:      skipModePickerSheet(title: "Skip Intro", selection: \.skipIntro)
        case .skipCredits:    skipModePickerSheet(title: "Skip Credits", selection: \.skipCredits)
        case .autoPlayNext:   autoPlayNextPickerSheet
        case .countdown:      countdownPickerSheet
        case .watchedDimming: watchedDimmingPickerSheet
        case .watchedLabelOpacity: watchedLabelOpacityPickerSheet
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
                    isSelected: viewModel.appearance.preference == option
                ) {
                    viewModel.appearance.preference = option
                    openPicker = nil
                }
            }
        }
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
    /// the system Mail composer to `support@aetherplayer.com` (with a `mailto:` fallback
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
            // "What's New" lives in About (the Version row opens it) — removed here
            // to avoid the duplicate entry point (#224).
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
                recipient: SupportDiagnostics.creatorEmail,
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
            recipient: SupportDiagnostics.creatorEmail,
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
                        .lineLimit(2)
                        .truncationMode(.tail)

                    Spacer(minLength: AetherDesign.Spacing.s)

                    Text("What's New")
                        .font(AetherDesign.Typography.metadata)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                        .lineLimit(1)

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
