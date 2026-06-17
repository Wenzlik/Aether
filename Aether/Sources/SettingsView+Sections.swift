import SwiftUI
import AetherCore
import UniformTypeIdentifiers

// MARK: - Settings sections (split from SettingsView.swift, #415)

extension SettingsView {
    // MARK: - Sections

    /// Compact Account (§1/§2). On iOS / iPadOS / visionOS each connected service
    /// is one row that opens a detail sheet (status + Sign Out) — destructive
    /// actions no longer sit permanently on screen, and a healthy "Connected"
    /// badge is dropped. **tvOS uses an inline variant instead:** modal sheets are
    /// fiddly to focus with the Siri Remote (the sheet's Sign Out was unreachable),
    /// and there's room here, so Sign Out stays a directly-focusable row.
    @ViewBuilder
    var accountSection: some View {
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
    var metadataSection: some View {
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

    // MARK: - Streaming Services (Netflix availability, #360)

    /// Opt-in switch + region for showing where a title is also available on
    /// Netflix (badges on owned titles; Netflix-only posters in Discover /
    /// Search). Off by default. Availability data is TMDb Watch Providers
    /// (powered by JustWatch) — no new key, so it rides on the TMDb token above.
    var streamingServicesSection: some View {
        AetherSettingsSection("Streaming Services") {
            settingsToggle(
                "Show Netflix availability",
                description: "Mark titles you own that are also on Netflix, and surface Netflix-only titles in Discover and Search. Aether links out — it never streams Netflix.",
                isOn: Binding(
                    get: { viewModel.streamingPreferences.netflixAvailabilityEnabled },
                    set: { viewModel.setNetflixAvailabilityEnabled($0) }
                )
            )
            if viewModel.streamingPreferences.netflixAvailabilityEnabled {
                settingsToggle(
                    "Show Netflix-only titles",
                    description: "Surface titles that aren't in your library but are on Netflix as posters in Discover and Search. Turn off to keep those screens to what you own — owned titles still get the badge.",
                    isOn: Binding(
                        get: { viewModel.streamingPreferences.showNetflixOnlyTitles },
                        set: { viewModel.streamingPreferences.showNetflixOnlyTitles = $0 }
                    )
                )
                AetherDisclosureRow(
                    label: "Region",
                    value: regionDisplayName(viewModel.resolvedNetflixRegion)
                ) { openPicker = .netflixRegion }
                if !viewModel.isTMDbConfigured {
                    Text("Add a TMDb token above to enable availability lookups.")
                        .font(AetherDesign.Typography.caption)
                        .foregroundStyle(AetherDesign.Palette.warning)
                        .padding(.horizontal, AetherDesign.Spacing.m)
                }
                Text("Availability data by JustWatch.")
                    .font(AetherDesign.Typography.caption)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
                    .padding(.horizontal, AetherDesign.Spacing.m)
                    .padding(.bottom, AetherDesign.Spacing.xs)
            }
        }
    }

    /// Region codes Netflix availability can be checked against — the common
    /// markets, "follow device" first. Display names are localized through the
    /// app locale (not `Locale.current`), per the localization rules.
    private static let netflixRegions = [
        "US", "GB", "CA", "AU", "IE",
        "CZ", "SK", "DE", "AT", "CH", "FR", "ES", "IT", "NL", "BE", "PL",
        "SE", "NO", "DK", "FI", "PT", "BR", "MX", "JP", "KR", "IN"
    ]

    /// A region's localized country name (e.g. "United States"), via the app
    /// locale. Falls back to the raw code.
    private func regionDisplayName(_ code: String) -> String {
        locale.localizedString(forRegionCode: code) ?? code
    }

    var netflixRegionPickerSheet: some View {
        PreferencePickerSheet(title: "Region") {
            // "Follow device" clears the explicit choice (region = nil).
            AetherSelectionRow(
                title: String(localized: "Follow device") + " (\(regionDisplayName(deviceRegionCode)))",
                isSelected: viewModel.streamingPreferences.region == nil
            ) {
                viewModel.setNetflixRegion(nil)
                openPicker = nil
            }
            ForEach(Self.netflixRegions, id: \.self) { code in
                AetherSelectionRow(
                    title: regionDisplayName(code),
                    isSelected: viewModel.streamingPreferences.region == code
                ) {
                    viewModel.setNetflixRegion(code)
                    openPicker = nil
                }
            }
        }
    }

    private var deviceRegionCode: String { Locale.current.region?.identifier ?? "US" }

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

            if viewModel.isEmbySignedIn {
                AetherSettingsRow(
                    label: "Emby",
                    value: accountRowValue(.emby, serverName: viewModel.embyServerName)
                ) { accountSheet = .emby }
            } else {
                AetherSettingsRow(label: "Emby", status: .notConnected) { viewModel.connectEmby() }
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
                // Multi-server manager (#325) — Apple TV can now see every
                // connected Plex server and choose the primary one to stream from.
                AetherSettingsRow(label: "Plex Servers", value: viewModel.plexServerSummary) {
                    isPickingPlexServer = true
                }
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

            if viewModel.isEmbySignedIn {
                AetherSettingsRow(label: "Emby", value: accountRowValue(.emby, serverName: viewModel.embyServerName))
                if viewModel.canSwitchSources && !viewModel.isActiveSource(.emby) {
                    AetherSettingsRow(label: "Set Emby as Active Source", actionRole: .primary) { viewModel.setActive(.emby) }
                }
                AetherSettingsRow(
                    label: isSigningOutEmby ? "Signing out…" : "Sign Out of Emby",
                    actionRole: .destructive
                ) { Task { await performSignOutEmby() } }
                .disabled(isSigningOutEmby)
            } else {
                AetherSettingsRow(label: "Emby", status: .notConnected) { viewModel.connectEmby() }
            }

            if viewModel.isSMBConnected {
                smbDisclosure
            } else {
                AetherSettingsRow(label: "SMB", status: .notConnected) { viewModel.connectSMB() }
            }
        }
        // Reachable on tvOS (no account sheet there) so Apple TV can manage
        // servers + primary inline (#325).
        .sheet(isPresented: $isPickingPlexServer) { plexServerPicker }
    }
    #endif

    /// The Plex multi-server manager (#325) — enable/disable servers and pick the
    /// primary streaming server. Shared by the iOS account sheet and the tvOS
    /// inline Account row, so Apple TV can see + choose servers too.
    private var plexServerPicker: some View {
        PlexServerPickerSheet(
            enabledIDs: viewModel.enabledPlexServerIDs,
            load: { await viewModel.availablePlexServers() },
            onToggle: { await viewModel.setPlexServerEnabled($0, enabled: $1) },
            primaryServerID: viewModel.primaryPlexServerID,
            onSetPrimary: { await viewModel.setPrimaryPlexServer($0) }
        )
    }

    /// Per-source detail sheet opened from the compact Account rows.
    @ViewBuilder
    func accountSheetView(for sheet: AccountSheet) -> some View {
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
            .sheet(isPresented: $isPickingPlexServer) { plexServerPicker }
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
        case .emby:
            SourceAccountSheet(
                title: "Emby",
                serverName: viewModel.embyServerName,
                status: (viewModel.canSwitchSources && viewModel.isActiveSource(.emby)) ? .neutral("Active") : .connected,
                canSetActive: viewModel.canSwitchSources && !viewModel.isActiveSource(.emby),
                isSigningOut: isSigningOutEmby,
                onSetActive: { viewModel.setActive(.emby); accountSheet = nil },
                onSignOut: { Task { await performSignOutEmby(); accountSheet = nil } },
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
    var localLibrarySection: some View {
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
    var downloadsSection: some View {
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
    var playbackSection: some View {
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
    var watchedDisplaySection: some View {
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
    var appearanceSection: some View {
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
    var supportSection: some View {
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
    func supportSheetView(for sheet: SupportSheet) -> some View {
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
    var aboutSection: some View {
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
    func infoSheetView(for sheet: InfoSheet) -> some View {
        switch sheet {
        case .about:
            AboutView(versionLabel: viewModel.versionRowLabel) { infoSheet = nil }
        case .diagnostics:
            DiagnosticsView(gather: { await viewModel.gatherDiagnostics() }) { infoSheet = nil }
        }
    }

    /// Hidden developer mode (unlocked by tapping the wordmark in About). Internal
    /// build / device / cache facts — not a polished surface, just the details.
    var developerSection: some View {
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
}
