import SwiftUI
import AetherCore
#if os(tvOS)
import UIKit
#endif

// MARK: - tvOS Accounts & Sources redesign (#441)
//
// The flat list (one source spread across account / set-active / sign-out rows)
// wasted the 10-foot canvas: full-bleed rows leave the screen's centre empty and
// promote destructive Sign Out to the index. The redesign reads the way the rest
// of Aether does on tvOS — large focusable **tiles**. Connected sources are tiles
// (logo + name + server + an Active badge); unconnected ones are lighter "Add
// Source" tiles. Per-source management (set active, manage servers, sign out)
// moves into a pushed detail screen, so the index stays calm and the focus
// engine has real targets to lift.

#if os(tvOS)
extension SettingsView {

    /// Pushed per-source detail target (tvOS). Registered on the Settings stack.
    enum SourceDetailRoute: String, Hashable, Identifiable {
        case plex, jellyfin, emby, smb
        var id: String { rawValue }
    }

    /// The tvOS replacement for the old inline Account section: two tile groups,
    /// **Connected Sources** then **Add Source**. Either group is omitted when
    /// empty, so a fresh install opens straight onto "Add Source" and a fully
    /// wired one never shows an empty "Add" group.
    @ViewBuilder
    var accountSectionTiles: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
            let connected = connectedSourceTiles
            let toAdd = addSourceTiles
            if !connected.isEmpty {
                sourceTileGroup("Connected Sources", tiles: connected)
            }
            if !toAdd.isEmpty {
                sourceTileGroup("Add Source", tiles: toAdd)
            }
        }
    }

    /// A titled grid of source tiles — two columns of large couch-readable cards.
    private func sourceTileGroup(_ title: LocalizedStringKey, tiles: [SourceTileSpec]) -> some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.s) {
            Text(title)
                .textCase(.uppercase)
                .font(AetherDesign.Typography.caption)
                .foregroundStyle(AetherDesign.Palette.textTertiary)
                .tracking(0.6)
                .padding(.horizontal, AetherDesign.Spacing.s)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: AetherDesign.Spacing.l),
                    GridItem(.flexible(), spacing: AetherDesign.Spacing.l),
                ],
                spacing: AetherDesign.Spacing.l
            ) {
                ForEach(tiles) { tile in
                    if let route = tile.route {
                        NavigationLink(value: route) { SourceTile(spec: tile) }
                            .buttonStyle(.plain)
                    } else if let connect = tile.connect {
                        Button(action: connect) { SourceTile(spec: tile) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        // Right/Left between the two groups jumps as a block, not row-by-row.
        .focusSection()
    }

    // MARK: Tile models

    /// Connected sources → tiles that push a detail screen. The Active badge is
    /// only meaningful (and only shown) when more than one switchable source is
    /// connected, mirroring `accountRowValue`.
    private var connectedSourceTiles: [SourceTileSpec] {
        var tiles: [SourceTileSpec] = []
        if viewModel.isPlexSignedIn {
            tiles.append(.connected(
                .plex, name: "Plex", subtitle: viewModel.plexServerSummary ?? viewModel.connectedServerName,
                isActive: viewModel.canSwitchSources && viewModel.isActiveSource(.plex)
            ))
        }
        if viewModel.isJellyfinSignedIn {
            tiles.append(.connected(
                .jellyfin, name: "Jellyfin", subtitle: viewModel.jellyfinServerName,
                isActive: viewModel.canSwitchSources && viewModel.isActiveSource(.jellyfin)
            ))
        }
        if viewModel.isEmbySignedIn {
            tiles.append(.connected(
                .emby, name: "Emby", subtitle: viewModel.embyServerName,
                isActive: viewModel.canSwitchSources && viewModel.isActiveSource(.emby)
            ))
        }
        if viewModel.isSMBConnected {
            tiles.append(.connected(
                .smb, name: "SMB",
                subtitle: viewModel.isSMBReachable ? (viewModel.smbServerName ?? "Connected") : "Dormant",
                isActive: false
            ))
        }
        return tiles
    }

    /// Unconnected sources → lighter tiles whose action kicks off the sign-in
    /// flow directly (no detail screen behind something you haven't set up yet).
    private var addSourceTiles: [SourceTileSpec] {
        var tiles: [SourceTileSpec] = []
        if !viewModel.isPlexSignedIn {
            tiles.append(.add(.plex, name: "Plex") { viewModel.connect() })
        }
        if !viewModel.isJellyfinSignedIn {
            tiles.append(.add(.jellyfin, name: "Jellyfin") { viewModel.connectJellyfin() })
        }
        if !viewModel.isEmbySignedIn {
            tiles.append(.add(.emby, name: "Emby") { viewModel.connectEmby() })
        }
        if !viewModel.isSMBConnected {
            tiles.append(.add(.smb, name: "SMB") { viewModel.connectSMB() })
        }
        return tiles
    }

    // MARK: Detail screens

    /// The pushed detail for a connected source — set active, manage servers
    /// (Plex), SMB folders/re-match, and the destructive Sign Out (now behind a
    /// confirmation, one level down from the index).
    @ViewBuilder
    func sourceDetailScreen(_ route: SourceDetailRoute) -> some View {
        switch route {
        case .plex:
            SourceDetailScreen(
                spec: .connected(.plex, name: "Plex", subtitle: viewModel.plexServerSummary ?? viewModel.connectedServerName,
                                  isActive: viewModel.canSwitchSources && viewModel.isActiveSource(.plex)),
                canSetActive: viewModel.canSwitchSources && !viewModel.isActiveSource(.plex),
                onSetActive: { viewModel.setActive(.plex) },
                onManageServers: { isPickingPlexServer = true },
                isSigningOut: isSigningOut,
                signOutLabel: "Sign Out of Plex",
                onSignOut: { Task { await performSignOut() } }
            ) { EmptyView() }
            .sheet(isPresented: $isPickingPlexServer) { plexServerPicker }
        case .jellyfin:
            SourceDetailScreen(
                spec: .connected(.jellyfin, name: "Jellyfin", subtitle: viewModel.jellyfinServerName,
                                  isActive: viewModel.canSwitchSources && viewModel.isActiveSource(.jellyfin)),
                canSetActive: viewModel.canSwitchSources && !viewModel.isActiveSource(.jellyfin),
                onSetActive: { viewModel.setActive(.jellyfin) },
                isSigningOut: isSigningOutJellyfin,
                signOutLabel: "Sign Out of Jellyfin",
                onSignOut: { Task { await performSignOutJellyfin() } }
            ) { EmptyView() }
        case .emby:
            SourceDetailScreen(
                spec: .connected(.emby, name: "Emby", subtitle: viewModel.embyServerName,
                                  isActive: viewModel.canSwitchSources && viewModel.isActiveSource(.emby)),
                canSetActive: viewModel.canSwitchSources && !viewModel.isActiveSource(.emby),
                onSetActive: { viewModel.setActive(.emby) },
                isSigningOut: isSigningOutEmby,
                signOutLabel: "Sign Out of Emby",
                onSignOut: { Task { await performSignOutEmby() } }
            ) { EmptyView() }
        case .smb:
            SourceDetailScreen(
                spec: .connected(.smb, name: "SMB",
                                  subtitle: viewModel.isSMBReachable ? (viewModel.smbServerName ?? "Connected") : "Dormant",
                                  isActive: false),
                canSetActive: false,
                isSigningOut: false,
                signOutLabel: "Disconnect SMB",
                onSignOut: { Task { await viewModel.signOutOfSMB() } }
            ) {
                smbDetailRows
            }
            .sheet(isPresented: $isEditingSMBFolders, onDismiss: {
                Task { await viewModel.updateSMBRoots(smbEditRoots, rootContent: smbEditRootContent) }
            }) {
                if let connection = viewModel.smbConnection {
                    SMBFolderPickerView(connection: connection, selectedRoots: $smbEditRoots, rootContent: $smbEditRootContent)
                }
            }
        }
    }

    /// SMB-specific rows for its detail screen — folders, poster-match summary,
    /// and a re-match action. (The disconnect lives in the shared screen's Sign
    /// Out slot.)
    @ViewBuilder
    private var smbDetailRows: some View {
        AetherSettingsSection("Library") {
            AetherSettingsRow(label: "Folders", value: smbDetailFoldersValue) {
                smbEditRoots = viewModel.smbConnection?.roots ?? []
                smbEditRootContent = viewModel.smbConnection?.rootContent ?? [:]
                isEditingSMBFolders = true
            }
            AetherSettingsRow(label: "Posters Matched", value: smbMatchSummary ?? "Open Library to match")
            AetherSettingsRow(label: isRematching ? "Re-matching…" : "Re-match Posters", actionRole: .primary) {
                Task {
                    isRematching = true
                    await viewModel.refreshSMB()
                    smbMatchSummary = (await viewModel.smbMatchSummary()).map { "\($0.matched) / \($0.total)" }
                    isRematching = false
                }
            }
            .disabled(isRematching)
        }
    }

    private var smbDetailFoldersValue: String {
        let count = viewModel.smbFolderCount
        if count == 0 { return "All shares" }
        return "\(count) folder\(count == 1 ? "" : "s")"
    }
}

// MARK: - Tile spec + views

/// Describes one source tile. `route` set → connected (pushes detail); `connect`
/// set → unconnected (kicks off sign-in). Exactly one of the two is non-nil.
struct SourceTileSpec: Identifiable {
    let id: String
    let route: SettingsView.SourceDetailRoute?
    let name: LocalizedStringKey
    let rawName: String
    let isActive: Bool
    let subtitle: String?
    let connect: (() -> Void)?

    static func connected(_ route: SettingsView.SourceDetailRoute, name: String, subtitle: String?, isActive: Bool) -> SourceTileSpec {
        SourceTileSpec(id: route.rawValue, route: route, name: LocalizedStringKey(name), rawName: name,
                       isActive: isActive, subtitle: subtitle, connect: nil)
    }

    static func add(_ route: SettingsView.SourceDetailRoute, name: String, connect: @escaping () -> Void) -> SourceTileSpec {
        SourceTileSpec(id: "add-\(route.rawValue)", route: nil, name: LocalizedStringKey(name), rawName: name,
                       isActive: false, subtitle: nil, connect: connect)
    }

    /// SF Symbol + tint standing in for the source's brand mark (a proper logo
    /// asset is a later polish pass — these read clearly at couch distance).
    var symbol: String {
        switch route?.rawValue ?? id.replacingOccurrences(of: "add-", with: "") {
        case "plex":     return "play.rectangle.fill"
        case "jellyfin": return "film.stack.fill"
        case "emby":     return "play.circle.fill"
        case "smb":      return "externaldrive.connected.to.line.below.fill"
        default:         return "server.rack"
        }
    }

    var tint: Color {
        switch route?.rawValue ?? id.replacingOccurrences(of: "add-", with: "") {
        case "plex":     return Color(red: 0.90, green: 0.62, blue: 0.0)   // Plex amber
        case "jellyfin": return Color(red: 0.46, green: 0.30, blue: 0.78)  // Jellyfin purple
        case "emby":     return Color(red: 0.30, green: 0.69, blue: 0.31)  // Emby green
        case "smb":      return AetherDesign.Palette.accent
        default:         return AetherDesign.Palette.accent
        }
    }

    /// Official brand-logo asset name for this source, used in preference to the
    /// SF Symbol fallback when the image is present in the catalog. The logos are
    /// trademarked, so the asset slots ship empty — drop each vendor's official
    /// mark into `Source{Plex,Jellyfin,Emby}.imageset` and it renders
    /// automatically (`SourceGlyph` falls back to `symbol` until then). SMB has no
    /// vendor logo, so it stays on the SF Symbol.
    var logoAsset: String? {
        switch route?.rawValue ?? id.replacingOccurrences(of: "add-", with: "") {
        case "plex":     return "SourcePlex"
        case "jellyfin": return "SourceJellyfin"
        case "emby":     return "SourceEmby"
        default:         return nil
        }
    }

    var isConnected: Bool { route != nil }
}

/// The mark inside a source's tinted rounded square: the official brand logo when
/// its asset is present, otherwise the SF Symbol fallback. Keeps a single render
/// path so tiles and the detail header stay identical, and so dropping in a logo
/// later needs no code change. (#441)
struct SourceGlyph: View {
    let asset: String?
    let symbol: String
    let color: Color
    /// Container edge length; the symbol renders at ~half, the logo insets a touch.
    let size: CGFloat

    var body: some View {
        if let asset, UIImage(named: asset) != nil {
            // Monochrome brand marks ship as template vectors, so they tint to the
            // source's brand colour the same way the SF Symbol fallback does.
            Image(asset)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(color)
                .padding(size * 0.2)
                .frame(width: size, height: size)
        } else {
            Image(systemName: symbol)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(color)
        }
    }
}

/// One large focusable source tile. Connected tiles are full-strength (logo,
/// name, server, optional Active badge); Add tiles are lighter and overlay a
/// plus on the mark.
struct SourceTile: View {
    let spec: SourceTileSpec

    var body: some View {
        // Logo (with an optional Active badge) then the name/subtitle directly
        // beneath it — grouped at the top-left so the tile sizes to its content
        // instead of stretching into a big empty box (the original "wastes space"
        // complaint, recreated in tile form). #441 feedback.
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            HStack(alignment: .top) {
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(spec.tint.opacity(spec.isConnected ? 0.22 : 0.12))
                        .frame(width: 52, height: 52)
                        .overlay {
                            SourceGlyph(
                                asset: spec.logoAsset,
                                symbol: spec.symbol,
                                color: spec.isConnected ? spec.tint : AetherDesign.Palette.textTertiary,
                                size: 52
                            )
                        }
                    if !spec.isConnected {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(AetherDesign.Palette.accent, AetherDesign.Palette.surface)
                            .offset(x: 5, y: 5)
                    }
                }
                Spacer(minLength: 0)
                if spec.isActive {
                    Text("Active")
                        .font(AetherDesign.Typography.metadata)
                        .foregroundStyle(AetherDesign.Palette.accent)
                        .padding(.horizontal, AetherDesign.Spacing.s)
                        .padding(.vertical, 4)
                        .background(AetherDesign.Palette.accent.opacity(0.16), in: Capsule())
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(spec.name)
                    .font(AetherDesign.Typography.cardTitle)
                    .foregroundStyle(spec.isConnected ? AetherDesign.Palette.textPrimary : AetherDesign.Palette.textSecondary)
                Text(spec.subtitle ?? String(localized: "Not connected"))
                    .font(AetherDesign.Typography.caption)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(AetherDesign.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                .fill(AetherDesign.Palette.surface.opacity(spec.isConnected ? 1 : 0.55))
        )
        .overlay {
            RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                .strokeBorder(AetherDesign.Palette.separator, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous))
        .premiumFocus()
    }
}

/// A category tile for the tvOS Settings landing grid — icon, title, subtitle,
/// the same focus lift as the source tiles so the whole Settings surface reads
/// consistently (objects/navigation are tiles; value rows stay lists). (#441)
struct SettingsCategoryTile: View {
    let systemImage: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(AetherDesign.Palette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AetherDesign.Typography.cardTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                Text(subtitle)
                    .font(AetherDesign.Typography.caption)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AetherDesign.Spacing.l)
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                .fill(AetherDesign.Palette.surface)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                .strokeBorder(AetherDesign.Palette.separator, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous))
        .premiumFocus()
    }
}

/// The pushed per-source detail screen (tvOS). Pins its own title above a
/// scroll of management rows, ending in a destructive Sign Out gated by a
/// confirmation — destructive actions no longer sit on the index.
struct SourceDetailScreen<Extra: View>: View {
    let spec: SourceTileSpec
    var canSetActive: Bool = false
    var onSetActive: (() -> Void)? = nil
    var onManageServers: (() -> Void)? = nil
    let isSigningOut: Bool
    let signOutLabel: String
    let onSignOut: () -> Void
    @ViewBuilder var extraSections: () -> Extra

    @State private var confirmSignOut = false

    init(
        spec: SourceTileSpec,
        canSetActive: Bool = false,
        onSetActive: (() -> Void)? = nil,
        onManageServers: (() -> Void)? = nil,
        isSigningOut: Bool,
        signOutLabel: String,
        onSignOut: @escaping () -> Void,
        @ViewBuilder extraSections: @escaping () -> Extra
    ) {
        self.spec = spec
        self.canSetActive = canSetActive
        self.onSetActive = onSetActive
        self.onManageServers = onManageServers
        self.isSigningOut = isSigningOut
        self.signOutLabel = signOutLabel
        self.onSignOut = onSignOut
        self.extraSections = extraSections
    }

    var body: some View {
        ZStack {
            AetherDesign.Gradients.background.ignoresSafeArea()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                    header

                    AetherSettingsSection("Connection") {
                        if let subtitle = spec.subtitle {
                            AetherSettingsRow(label: "Server", value: subtitle)
                        }
                        if let onManageServers {
                            AetherSettingsRow(
                                label: "Manage Servers",
                                description: "Turn servers on your account on or off — content from several is merged.",
                                systemImage: "rack",
                                value: nil,
                                action: onManageServers
                            )
                        }
                    }

                    if canSetActive, let onSetActive {
                        AetherSettingsSection("Library") {
                            AetherSettingsRow(
                                label: "Set as Active Source",
                                description: "Browse this server in your Library.",
                                actionRole: .primary,
                                action: onSetActive
                            )
                        }
                    }

                    extraSections()

                    AetherSettingsSection("Account") {
                        AetherSettingsRow(
                            label: isSigningOut ? "Signing out…" : signOutLabel,
                            actionRole: .destructive
                        ) { confirmSignOut = true }
                        .disabled(isSigningOut)
                    }
                }
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.vertical, AetherDesign.Spacing.xl)
                .padding(.horizontal, AetherDesign.Spacing.xxl)
            }
        }
        .confirmationDialog(
            "Sign out of \(spec.rawName)?",
            isPresented: $confirmSignOut,
            titleVisibility: .visible
        ) {
            Button(signOutLabel, role: .destructive) { onSignOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can sign back in any time. Downloads and settings stay on this device.")
        }
    }

    private var header: some View {
        HStack(spacing: AetherDesign.Spacing.l) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(spec.tint.opacity(0.22))
                .frame(width: 76, height: 76)
                .overlay {
                    SourceGlyph(asset: spec.logoAsset, symbol: spec.symbol, color: spec.tint, size: 76)
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(spec.name)
                    .font(AetherDesign.Typography.heroTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                if spec.isActive {
                    Text("Active source")
                        .font(AetherDesign.Typography.caption)
                        .foregroundStyle(AetherDesign.Palette.accent)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
#endif
