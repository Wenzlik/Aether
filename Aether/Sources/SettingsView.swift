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

    @State var isSigningOut = false
    @State var isSigningOutJellyfin = false
    @State var isSigningOutEmby = false
    @State var isWhatsNewPresented = false
    @State var isImportingLocal = false
    @State var isRematching = false
    @State var openPicker: PrefPicker?
    /// Device volume stats for the Storage Summary card. `nil` until the probe
    /// runs (and stays nil if it fails) — the free-space row just hides.
    @State private var deviceCapacity: DeviceCapacity?
    /// Current on-disk artwork cache size, shown next to "Clear Image Cache".
    @State var imageCacheBytes: Int = 0
    /// Gate the (destructive) cache clear behind a confirmation — it used to wipe
    /// on a single tap, which was easy to hit by accident.
    @State private var showClearCacheConfirm = false
    /// "119 / 417" matched, once the SMB library has been browsed this session.
    @State var smbMatchSummary: String?
    /// SMB details (account, match count, downloads, actions) tuck under an
    /// expandable row so the Account section stays calm; expanded by tap.
    @State var smbExpanded = false
    /// Presents the TMDb token editor (#214 — user fallback / override).
    @State var isEditingTMDbToken = false
    /// Presents the Plex server picker — switch servers when the account can
    /// reach more than one (#323). Opened from the Plex account sheet.
    @State var isPickingPlexServer = false
    /// Presents the Plex Home profile switcher (#326). Opened from the Plex
    /// account sheet when the account has Home profiles.
    @State var isSwitchingPlexProfile = false
    /// Presents the SMB folder picker for the *connected* share (add/remove
    /// folders after sign-in, #214), seeded with the current roots.
    @State var isEditingSMBFolders = false
    @State var smbEditRoots: [String] = []
    @State var smbEditRootContent: [String: SMBRootContent] = [:]
    #if os(iOS)
    /// Alternate app-icon chooser (iOS / iPadOS only).
    @State var appIconStore = AppIconStore()
    #endif
    /// Drives the split: a two-column dashboard on roomy surfaces, a single
    /// column on the phone.
    @Environment(\.horizontalSizeClass) private var hSizeClass

    /// The app locale (UI-language override aware) — used to localize the
    /// Netflix region country names (#360), per localization rule (c).
    @Environment(\.locale) var locale

    /// Identifier for whichever default-pref sheet is open. Driven via
    /// `.sheet(item:)` so the picker contents reflect the row tapped.
    enum PrefPicker: String, Identifiable {
        case quality, audio, subtitles, appearance, language, skipIntro, skipCredits, autoPlayNext, countdown, watchedDimming, watchedLabelOpacity
        case posterRatingSource
        case netflixRegion
        #if os(iOS)
        case appIcon
        #endif
        #if os(visionOS)
        case cinemaScreen, cinemaSeat, cinemaEnvironment
        #endif
        var id: String { rawValue }
    }

    /// Push targets inside the Settings stack.
    enum SettingsRoute: Hashable {
        case downloads
    }

    #if !os(tvOS)
    /// Which Support flow sheet is open. tvOS has no mail composer, so the whole
    /// Support section is compiled out there.
    enum SupportSheet: String, Identifiable {
        case reportBug, featureRequest, contact, sendDiagnostics
        var id: String { rawValue }
    }
    @State var supportSheet: SupportSheet?
    /// `mailto:` fallback when no Mail account is configured.
    @Environment(\.openURL) var openURL
    #endif

    /// About / Diagnostics info sheets (all platforms).
    enum InfoSheet: String, Identifiable {
        case about, diagnostics
        var id: String { rawValue }
    }
    @State var infoSheet: InfoSheet?

    /// Which connected source's detail sheet is open. Tapping a compact Account
    /// row opens it; it holds the server, status, and the (rarely-used,
    /// previously always-exposed) Sign Out action.
    enum AccountSheet: String, Identifiable {
        case plex, jellyfin, emby
        var id: String { rawValue }
    }
    @State var accountSheet: AccountSheet?
    /// Triggers the "Add Source" confirmation dialog (non-tvOS).
    @State var isAddingSource = false

    /// Hidden developer mode, unlocked by tapping the wordmark in About.
    @AppStorage("developer.unlocked") var developerUnlocked = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                AetherDesign.Gradients.background.ignoresSafeArea()

                #if os(tvOS)
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
                #else
                // iOS 26 sidebar layout reports wrong dimensions to GeometryReader —
                // use padding + maxWidth so content sizes off the real container.
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                        // On iPad the floating top tab bar is the chrome — an inline
                        // wordmark would slide under it (#settings-wordmark).
                        if !usesTopBarChrome { header }
                        settingsIndex
                    }
                    .padding(.horizontal, AetherDesign.Spacing.l)
                    .padding(.top, AetherDesign.Spacing.l)
                    .padding(.bottom, AetherDesign.Spacing.xxl)
                    .frame(maxWidth: isWide ? 1100 : .infinity)
                    .frame(maxWidth: .infinity)
                }
                .task {
                    await refreshCapacity()
                    imageCacheBytes = await Task.detached { AetherImageCache.shared.diskUsageBytes() }.value
                }
                #endif
            }
            // The root Settings surface carries its own wordmark, so suppress the
            // empty navigation bar; pushed screens (Downloads) show their own.
            #if os(iOS) || os(visionOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .navigationDestination(for: SettingsCategory.self) { category in
                categoryScreen(category)
            }
            #if os(tvOS)
            // Per-source detail pushed from a Connected Sources tile (#441).
            .navigationDestination(for: SourceDetailRoute.self) { route in
                sourceDetailScreen(route)
            }
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
                history: viewModel.releaseHistory
            ) { isWhatsNewPresented = false }
        }
        #if os(tvOS)
        .fullScreenCover(item: $infoSheet) { sheet in infoSheetView(for: sheet) }
        #else
        .sheet(item: $infoSheet) { sheet in infoSheetView(for: sheet) }
        #endif
        .sheet(item: $accountSheet) { sheet in
            accountSheetView(for: sheet)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
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
            Task { await viewModel.updateSMBRoots(smbEditRoots, rootContent: smbEditRootContent) }
        }) {
            if let connection = viewModel.smbConnection {
                SMBFolderPickerView(connection: connection, selectedRoots: $smbEditRoots, rootContent: $smbEditRootContent)
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
        // Titles / subtitles / icons are platform-aware: tvOS compiles out
        // downloads, storage, local-file import, app-icon, and the mail-backed
        // Support flows, so the shared copy ("…and local files", "Downloads,
        // storage, and cache") would promise things that don't exist there (#441).
        var title: String {
            switch self {
            case .accountsSources: return "Accounts & Sources"
            case .playback: return "Playback"
            case .libraryDownloads:
                #if os(tvOS)
                return "Storage"
                #else
                return "Library & Downloads"
                #endif
            case .appearance: return "Appearance"
            case .supportAbout: return "Support & About"
            }
        }
        var subtitle: String {
            switch self {
            case .accountsSources:
                #if os(tvOS)
                return "Plex, Jellyfin, and SMB"
                #else
                return "Plex, Jellyfin, SMB, and local files"
                #endif
            case .playback: return "Quality, audio & subtitles, skip"
            case .libraryDownloads:
                #if os(tvOS)
                return "Image cache"
                #else
                return "Downloads, storage, and cache"
                #endif
            case .appearance:
                #if os(tvOS)
                return "Theme and watched titles"
                #else
                return "Theme, app icon, and watched titles"
                #endif
            case .supportAbout:
                #if os(tvOS)
                return "Diagnostics and about"
                #else
                return "Report a bug, diagnostics, about"
                #endif
            }
        }
        var systemImage: String {
            switch self {
            case .accountsSources: return "person.2.circle.fill"
            case .playback: return "play.circle.fill"
            case .libraryDownloads:
                #if os(tvOS)
                return "internaldrive.fill"
                #else
                return "arrow.down.circle.fill"
                #endif
            case .appearance: return "paintbrush.fill"
            case .supportAbout: return "questionmark.circle.fill"
            }
        }
    }

    @ViewBuilder
    private var settingsIndex: some View {
        #if os(tvOS)
        // tvOS landing is the first thing you see — a full-width row list wastes
        // the 10-foot canvas exactly like the old Accounts list did, so the index
        // is a tile grid (consistent with the source tiles one level down, #441).
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: AetherDesign.Spacing.l),
                GridItem(.flexible(), spacing: AetherDesign.Spacing.l),
                GridItem(.flexible(), spacing: AetherDesign.Spacing.l),
            ],
            spacing: AetherDesign.Spacing.l
        ) {
            ForEach(SettingsCategory.allCases) { category in
                NavigationLink(value: category) {
                    SettingsCategoryTile(
                        systemImage: category.systemImage,
                        title: LocalizedStringKey(category.title),
                        subtitle: LocalizedStringKey(category.subtitle)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        #else
        if isWide {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: AetherDesign.Spacing.m),
                    GridItem(.flexible(), spacing: AetherDesign.Spacing.m),
                ],
                spacing: AetherDesign.Spacing.m
            ) {
                ForEach(SettingsCategory.allCases) { category in
                    NavigationLink(value: category) { categoryIndexCard(category) }
                        .buttonStyle(.plain)
                }
            }
        } else {
            VStack(spacing: AetherDesign.Spacing.m) {
                ForEach(SettingsCategory.allCases) { category in
                    NavigationLink(value: category) { categoryIndexCard(category) }
                        .buttonStyle(.plain)
                }
            }
        }
        #endif
    }

    /// One category's own screen — a single-column scroll of the relevant
    /// existing sections (no two-column dashboard, which is what clipped on
    /// iPad). Pushed onto the Settings `NavigationStack`.
    @ViewBuilder
    private func categoryScreen(_ category: SettingsCategory) -> some View {
        ZStack {
            AetherDesign.Gradients.background.ignoresSafeArea()
            GeometryReader { geo in
                #if os(tvOS)
                // tvOS renders `.navigationTitle` as a large title that floats
                // over / scrolls with the content rather than pinning — the same
                // GeometryReader+ScrollView fragility the iOS branch calls out
                // below, except tvOS has no nav bar to fall back on (#378). Pin
                // our own title above the scroll so it stays at the top while the
                // sections scroll beneath it (the expected tvOS pattern).
                VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                    Text(LocalizedStringKey(category.title))
                        .font(AetherDesign.Typography.heroTitle)
                        .foregroundStyle(AetherDesign.Palette.textPrimary)
                        .frame(width: settingsContentWidth(geo.size.width), alignment: .leading)
                        .frame(maxWidth: .infinity)
                        .padding(.top, AetherDesign.Spacing.l)

                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                            categorySections(category)
                        }
                        .padding(.bottom, AetherDesign.Spacing.xxl)
                        .frame(width: settingsContentWidth(geo.size.width))
                        .frame(maxWidth: .infinity)
                    }
                }
                #else
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                        categorySections(category)
                    }
                    .padding(.horizontal, AetherDesign.Spacing.l)
                    .padding(.top, AetherDesign.Spacing.l)
                    .padding(.bottom, AetherDesign.Spacing.xxl)
                    .frame(maxWidth: isWide ? 1100 : .infinity)
                    .frame(maxWidth: .infinity)
                }
                #endif
            }
        }
        // tvOS pins its own title above (see above), so suppress the floating
        // system title there; iOS/visionOS keep the nav-bar title.
        #if !os(tvOS)
        .navigationTitle(LocalizedStringKey(category.title))
        #endif
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
            streamingServicesSection
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

    /// Shared card for both the single-column (iPhone) and two-column grid (iPad/visionOS) index.
    #if !os(tvOS)
    private func categoryIndexCard(_ category: SettingsCategory) -> some View {
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
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                .fill(AetherDesign.Palette.surface)
        )
        .premiumFocus()
    }
    #endif

    /// iPad regular width shows the brand mark on the floating top tab bar, so
    /// the inline wordmark header is dropped there to avoid it sliding under the
    /// bar (matches Home / Library / Discover's `usesTopBarChrome`). iPhone
    /// (compact) and tvOS / visionOS keep the inline wordmark.
    private var usesTopBarChrome: Bool {
        #if os(iOS)
        hSizeClass == .regular
        #else
        false
        #endif
    }

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

    func formatBytes(_ bytes: Int64) -> String {
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
    func settingsToggle(_ title: String, description: String? = nil, isOn: Binding<Bool>) -> some View {
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

    // MARK: - Actions

    func performSignOut() async {
        isSigningOut = true
        await viewModel.signOut()
        isSigningOut = false
    }

    func performSignOutJellyfin() async {
        isSigningOutJellyfin = true
        await viewModel.signOutOfJellyfin()
        isSigningOutJellyfin = false
    }

    func performSignOutEmby() async {
        isSigningOutEmby = true
        await viewModel.signOutOfEmby()
        isSigningOutEmby = false
    }
}
