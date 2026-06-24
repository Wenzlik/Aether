import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import AetherCore

// #241 inc 6 — action surfaces: source switcher pill, the action row (play /
// resume / restart / cinema), watched + favorite toggles, the download control +
// menu, and the Netflix-only actions. Split out of DetailView.swift. (The watched
// toggle moved here too: for a file split the AppSession Environment is reachable
// from an extension, unlike the inc-3 VM extraction that had to keep it view-side.)
extension DetailView {

    // MARK: - Source switcher (compact, #380)

    /// Compact replacement for the old full-width "Available Sources" section
    /// (#380): a labelled `Menu` pill (e.g. `Plex ▾`) showing the active source.
    /// The menu lists every source — the active one checked, the preferred one
    /// tagged, the quality noted — and tapping a playable source re-points the
    /// whole screen (`selectSource`). Deliberately a *labelled* control rather
    /// than a cryptic tertiary icon, so it doesn't reintroduce the width-shifting
    /// blue glyph removed from the action row in #356. Only rendered when
    /// `availableSources.count > 1` (call-site guard).
    var sourceSwitcher: some View {
        Menu {
            ForEach(availableSources) { src in
                Button {
                    viewModel.selectSource(src)
                } label: {
                    sourceMenuRow(src)
                }
                .disabled(!src.playable)
            }
        } label: {
            sourceSwitcherLabel
        }
        // Strip the Menu's default accent button chrome so the pill reads as a
        // neutral secondary control (matches `downloadIconButton`, #356).
        .buttonStyle(.plain)
        .accessibilityLabel("Source")
    }

    /// The inline pill: a drive glyph, the active source's name, and a chevron.
    private var sourceSwitcherLabel: some View {
        let active = availableSources.first { $0.item.id == activeItem.id }
        return HStack(spacing: AetherDesign.Spacing.xs) {
            Image(systemName: "externaldrive")
                .font(.caption)
            Text(verbatim: active?.serverName ?? active?.kind.displayName ?? "")
                .font(AetherDesign.Typography.caption)
            Image(systemName: "chevron.down")
                .font(.caption2)
        }
        .foregroundStyle(AetherDesign.Palette.textSecondary)
        .padding(.horizontal, AetherDesign.Spacing.m)
        .padding(.vertical, AetherDesign.Spacing.xs)
        .background(AetherDesign.Materials.card, in: Capsule())
        .overlay(Capsule().strokeBorder(AetherDesign.Palette.separator, lineWidth: 1))
        .contentShape(Capsule())
        .premiumFocus()
    }

    /// One menu entry: a checkmark on the active source (otherwise the kind
    /// glyph), the server name, its quality if known, and a "Preferred" tag on
    /// the default source.
    @ViewBuilder
    private func sourceMenuRow(_ src: UnifiedSource) -> some View {
        let isActive = src.item.id == activeItem.id
        let isPreferred = src.item.id == item.id
        let name = src.serverName ?? src.kind.displayName
        let glyph = src.kind == .offline ? "arrow.down.circle" : "externaldrive"
        Label {
            sourceMenuTitle(name: name, quality: src.quality, isPreferred: isPreferred)
        } icon: {
            Image(systemName: isActive ? "checkmark" : glyph)
        }
    }

    /// `<server> · <quality> · Preferred` — the dynamic parts are verbatim
    /// (server name / resolution are data), only "Preferred" is localized. We
    /// resolve that segment with `String(localized:)` and compose one verbatim
    /// `Text`, avoiding the deprecated `Text` `+` concatenation (iOS 26).
    private func sourceMenuTitle(name: String, quality: String?, isPreferred: Bool) -> Text {
        let base = quality.map { "\(name) · \($0)" } ?? name
        guard isPreferred else { return Text(verbatim: base) }
        return Text(verbatim: "\(base) · \(String(localized: "Preferred"))")
    }

    /// Switch the screen to a different source. Resets the per-source state
    /// (hydration / playback / resume / children) so `.task(id:)` reloads it for
    /// the chosen server. Clearing `overrideItem` (selecting the preferred
    /// source) returns to the navigated item.
    // MARK: - Action row (Resume / Play From Beginning / Play, or unavailable)

    @ViewBuilder
    var actionRow: some View {
        if current.streamURL != nil {
            // Compact iPhone can't fit the whole cluster (Resume pill + Restart +
            // up to ~4 tertiary icons) on one line, and the old two-row layout is
            // gone — so let it scroll horizontally there instead of clipping. iPad
            // / tvOS / visionOS have the width, so they keep a plain row (no
            // scroll → no change to remote focus traversal on tvOS).
            #if os(iOS)
            if hSizeClass == .compact {
                ScrollView(.horizontal, showsIndicators: false) { actionCluster }
            } else {
                actionCluster
            }
            #else
            actionCluster
            #endif
        } else if isNetflixOnly {
            netflixOnlyActions
        } else {
            unavailableState
        }
    }

    /// The unified action cluster (#382, Infuse-style): the primary Resume/Play
    /// pill, Restart demoted to a borderless icon right after it, then the
    /// tertiary icons — all at one vertical level instead of a pill row stacked
    /// over a separate icon row. Play/Resume stays first so the tvOS remote lands
    /// on it (not the watched toggle), and every button is reachable left→right
    /// by the Siri Remote. Left-aligned by the parent column (no trailing Spacer,
    /// which would misbehave inside the compact-width horizontal ScrollView).
    private var actionCluster: some View {
        HStack(spacing: AetherDesign.Spacing.m) {
            if resume != nil { resumeButton } else { playButton }
            if resume != nil { restartIconButton }
            #if os(visionOS)
            watchInCinemaButton
            #endif
            compactActionButtons
        }
    }

    /// Tertiary actions as borderless icon buttons (#382) — Download · Watched ·
    /// Favorite · Details · etc. Returned as bare buttons (no enclosing HStack)
    /// so they drop straight into `actionRow`'s single horizontal cluster; each
    /// is a focusable `Button` / `Menu`, so the whole row stays reachable
    /// left/right by the tvOS remote.
    @ViewBuilder
    private var compactActionButtons: some View {
        if shouldShowDownloadControl {
            downloadIconButton
        }
        if source != nil {
            AetherIconButton(
                systemImage: isWatched ? "eye.fill" : "eye",
                accessibilityLabel: isWatched ? "Mark as unwatched" : "Mark as watched",
                isActive: isWatched
            ) {
                Task { await toggleWatched() }
            }
        }
        if source?.supportsFavorites == true {
            AetherIconButton(
                systemImage: isFavorite ? "heart.fill" : "heart",
                accessibilityLabel: isFavorite ? "Remove from favorites" : "Add to favorites",
                isActive: isFavorite
            ) {
                Task { await viewModel.toggleFavorite() }
            }
        }
        if viewModel.supportsUserRatings {
            ratingMenu
        }
        // Source switching is not a tertiary icon here: it lived as a cryptic,
        // width-shifting, blue-tinted glyph that collided with "blue = active"
        // (#356). It now has a labelled home in the body — the compact
        // `sourceSwitcher` pill (#380), shown when count > 1.
        if current.mediaInfo != nil {
            AetherIconButton(systemImage: "info.circle", accessibilityLabel: "Technical details") {
                presentedSelector = .technicalDetails
            }
        }
        // "Also on Netflix" (#360): a secondary link-out for an owned title
        // that's also on Netflix. Launch-capable platforms only (not tvOS).
        if ownedNetflixProvider != nil && NetflixLauncher.canLaunch {
            AetherIconButton(systemImage: "play.tv", accessibilityLabel: "Play on Netflix") {
                playOnNetflix()
            }
        }
        #if !os(tvOS)
        // Edit metadata — local items only (movies / episodes, not show
        // containers, whose id is "show:<series>" rather than an item id).
        if activeItem.id.source == .local && !activeItem.kind.isContainer {
            AetherIconButton(systemImage: "pencil", accessibilityLabel: "Edit metadata") {
                presentedSelector = .editMetadata
            }
        }
        #endif
        // SMB items carry no metadata — let the user correct the title/year (or
        // search TMDb and pick a match) so a mis-named file gets a poster (#213).
        // Movies, episodes, **and shows** (correcting a show fixes the whole
        // series); not seasons. Available on tvOS too.
        if isSMBSource(activeItem.id.source), activeItem.kind == .show || !activeItem.kind.isContainer {
            AetherIconButton(systemImage: "pencil", accessibilityLabel: "Edit title and year") {
                presentedSelector = .smbEditMetadata
            }
        }
    }

    /// Personal rating as a compact icon `Menu` (Plex `userRating`). The glyph
    /// fills when rated; the menu offers 1–5 stars (mapped to Plex's 0–10) and
    /// Clear. A Menu (not five inline taps) keeps the action row tidy and stays
    /// a single focusable element on tvOS.
    private var ratingMenu: some View {
        let rated = viewModel.userRating != nil
        let currentStars = Int(((viewModel.userRating ?? 0) / 2).rounded())
        return Menu {
            ForEach(Array((1...5).reversed()), id: \.self) { stars in
                Button {
                    Task { await viewModel.setRating(stars * 2) }
                } label: {
                    if stars == currentStars {
                        Label { Text(verbatim: String(repeating: "★", count: stars)) }
                            icon: { Image(systemName: "checkmark") }
                    } else {
                        Text(verbatim: String(repeating: "★", count: stars))
                    }
                }
            }
            if rated {
                Button("Clear Rating", role: .destructive) {
                    Task { await viewModel.setRating(0) }
                }
            }
        } label: {
            AetherIconCircleLabel(
                systemImage: rated ? "star.fill" : "star",
                isActive: rated
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Your rating")
    }

    /// Download as a compact icon `Menu`: the glyph reflects the current state,
    /// and the menu offers the state-appropriate actions (download / pause /
    /// resume / cancel / delete / retry), with the live status as a header.
    private var downloadIconButton: some View {
        Menu {
            downloadMenuContent
        } label: {
            AetherIconCircleLabel(
                systemImage: downloadGlyph,
                isActive: isDownloaded
            )
        }
        // Strip the Menu's default accent-tinted button chrome so the icon reads
        // identically to the plain `AetherIconButton`s in the row — blue is then
        // driven only by `isActive` (downloaded), never by the menu decoration,
        // keeping "blue = primary/active" consistent (#356 follow-up).
        .buttonStyle(.plain)
        .accessibilityLabel("Download")
    }

    /// True once the title is fully downloaded — tints the download icon as "done".
    private var isDownloaded: Bool {
        if case .completed = downloadStatus { return true }
        return false
    }

    private var downloadGlyph: String {
        switch downloadStatus {
        case .notDownloaded:            return "arrow.down.circle"
        case .queued, .downloading:     return "arrow.down.circle.dotted"
        case .paused:                   return "pause.circle"
        case .completed:                return "checkmark.circle.fill"
        case .failed:                   return "exclamationmark.circle"
        case .expired:                  return "arrow.clockwise.circle"
        }
    }

    @ViewBuilder
    private var downloadMenuContent: some View {
        switch downloadStatus {
        case .notDownloaded:
            Button {
                // SMB is a raw file share — no server transcode, so skip the
                // quality picker and download the original file directly.
                if isSMBSource(activeItem.id.source) {
                    Task { await viewModel.startDownload(quality: .original) }
                } else {
                    presentedSelector = .downloadQuality
                }
            } label: { Label("Download", systemImage: "arrow.down.circle") }
            .disabled(isEnqueuingDownload)
        case .queued:
            Text("Queued")
            Button(role: .destructive) { Task { await viewModel.cancelDownload() } } label: { Label("Cancel", systemImage: "xmark") }
        case let .downloading(fraction):
            Text("Downloading · \(DetailFormatting.percent(fraction))")
            Button { Task { await viewModel.pauseDownload() } } label: { Label("Pause", systemImage: "pause") }
            Button(role: .destructive) { Task { await viewModel.cancelDownload() } } label: { Label("Cancel", systemImage: "xmark") }
        case let .paused(fraction):
            Text("Paused at \(DetailFormatting.percent(fraction))")
            Button { Task { await viewModel.resumeDownload() } } label: { Label("Resume", systemImage: "play") }
            Button(role: .destructive) { Task { await viewModel.cancelDownload() } } label: { Label("Cancel", systemImage: "xmark") }
        case let .completed(_, size):
            Text("Downloaded · \(formatBytes(size))")
            Button(role: .destructive) { Task { await viewModel.removeDownload() } } label: { Label("Delete Download", systemImage: "trash") }
        case let .failed(reason):
            Text("Failed · \(reason)")
            Button { Task { await viewModel.retryDownload() } } label: { Label("Retry", systemImage: "arrow.clockwise") }
        case .expired:
            Text("Expired")
            Button { Task { await viewModel.retryDownload() } } label: { Label("Re-download", systemImage: "arrow.clockwise") }
        }
    }

    /// Displayed watched state (#241: derived in the VM). Kept here so the action
    /// row + `toggleWatched` read it unchanged.
    var isWatched: Bool { viewModel.isWatched }

    /// Marking watched fans out across every connected source via `AppSession`
    /// (an `@Environment`, unavailable at VM-init), so this stays view-side —
    /// same bucket as the playback launchers. The VM owns `watchedOverride` /
    /// `resume`, written here through the forwarders.
    private func toggleWatched() async {
        let next = !isWatched
        // Marking an **in-progress** title watched throws away its resume point.
        // Confirm first so a single tap can't silently wipe progress; un-marking
        // or marking a not-started title needs no confirmation.
        if next, resume != nil {
            confirmMarkWatched = true
            return
        }
        await setWatched(next)
    }

    func setWatched(_ next: Bool) async {
        watchedOverride = next   // optimistic
        // Sync across every source that has this title, not just `source` —
        // e.g. a movie on both Plex and Jellyfin flips on both.
        await appSession.markWatchedEverywhere(activeItem, watched: next)
        // Watched ends "in progress": drop the resume point so the title leaves
        // Continue Watching and never offers "Resume" a second before the end.
        if next {
            await resumeStore.clear(for: activeItem.id)
            resume = nil
        }
    }

    /// Favorite state (#241: derived in the VM). Kept here so the action row
    /// reads it unchanged.
    var isFavorite: Bool { viewModel.isFavorite }

    /// True when a Download surface should appear below the play buttons —
    /// only for Plex / Jellyfin items (the only sources that implement
    /// `downloadURL`), and only once the pipeline has booted.
    private var shouldShowDownloadControl: Bool {
        guard downloadManager != nil, source?.supportsDownloads == true else { return false }
        return true
    }

    /// "47%" — keeps the row stable as progress ticks (no decimals,
    /// always two digits at most).

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// Single "Play" button — shown when there's no saved resume point.
    private var playButton: some View {
        AetherButton(
            isPreparingPlayback ? "Preparing…" : "Play",
            systemImage: "play.fill",
            role: .primary
        ) {
            Task { await presentPlayer(fromStart: true) }
        }
        .disabled(isPreparingPlayback)
    }

    #if os(visionOS)
    /// visionOS-only: enter Cinema Mode — the same title on a cinematic screen
    /// in a dedicated immersive space, driven by the same `PlaybackSession`.
    /// Enters Cinema Mode. When a resume point exists, first asks whether to
    /// continue or start over (the immersive entry has no Resume/Restart pair of
    /// its own); otherwise starts from the top.
    private var watchInCinemaButton: some View {
        AetherButton(
            "Watch in Cinema",
            systemImage: "visionpro",
            role: .secondary
        ) {
            if resume != nil {
                showCinemaResumePrompt = true
            } else {
                Task { await watchInCinema(fromStart: false) }
            }
        }
        .disabled(isPreparingPlayback)
        .confirmationDialog(
            "Watch in Cinema",
            isPresented: $showCinemaResumePrompt,
            titleVisibility: .visible
        ) {
            Button(resume.map { "Continue from \(DetailFormatting.position($0.position))" } ?? "Continue") {
                Task { await watchInCinema(fromStart: false) }
            }
            Button("Start Over") {
                Task { await watchInCinema(fromStart: true) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
    #endif

    /// Primary action when a resume point exists — the position is carried
    /// **inline** in the label ("Resume 0:01:39") like the Infuse reference, so it
    /// sits as one pill next to Restart instead of a button + caption stack.
    private var resumeButton: some View {
        AetherButton(
            isPreparingPlayback ? "Preparing…" : "Resume \(DetailFormatting.position(resume?.position ?? .zero))",
            systemImage: "play.fill",
            role: .primary
        ) {
            Task { await presentPlayer(fromStart: false) }
        }
        .disabled(isPreparingPlayback)
    }

    /// Restart — demoted from a text pill to a borderless icon button right
    /// after the primary pill (#382), so the cluster reads as one row. The pill
    /// label already carries the resume time, so "from the beginning" only needs
    /// an icon. Disabled while playback is preparing, like the primary buttons.
    @ViewBuilder
    private var restartIconButton: some View {
        AetherIconButton(
            systemImage: "backward.end.fill",
            accessibilityLabel: "Play from beginning"
        ) {
            guard !isPreparingPlayback else { return }
            Task { await presentPlayer(fromStart: true) }
        }
        .opacity(isPreparingPlayback ? 0.4 : 1)
    }

    private var unavailableState: some View {
        AetherErrorState(
            glyph: "play.slash",
            title: "Playback unavailable",
            message: "This title isn't streamable yet. If it's a format Plex can't direct-play, transcode support lands in a future update."
        )
        .padding(.top, -AetherDesign.Spacing.xxl)
    }

    // MARK: - Netflix availability (#360)

    /// `true` when this is a Netflix-only title (no library source backs it) —
    /// its primary action is "Play on Netflix", not in-app playback.
    private var isNetflixOnly: Bool {
        if case .external = item.id.source { return true }
        return false
    }

    /// The Netflix provider for an **owned** title (badge + secondary action),
    /// or nil. External-only titles are handled by `isNetflixOnly` instead.
    private var ownedNetflixProvider: ExternalProvider? {
        guard !isNetflixOnly else { return nil }
        return appSession.watchAvailability.netflix(forTMDb: current.guids.tmdb, isShow: current.kind == .show)
    }

    /// Open the title on Netflix (app or web). No-op on tvOS (caller hides it).
    private func playOnNetflix() {
        guard let url = NetflixLauncher.searchURL(title: current.title) else { return }
        openURL(url)
    }

    /// Primary actions for a Netflix-only title: "Play on Netflix" where it can
    /// launch (iOS/iPadOS/macOS/visionOS), or an informational note on tvOS.
    @ViewBuilder
    private var netflixOnlyActions: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.s) {
            if NetflixLauncher.canLaunch {
                AetherButton("Play on Netflix", systemImage: "play.fill", role: .primary) {
                    playOnNetflix()
                }
            } else {
                Label("Available on Netflix", systemImage: "tv")
                    .font(AetherDesign.Typography.body)
                    .foregroundStyle(AetherDesign.Palette.textSecondary)
            }
            Text("Aether links out to Netflix — it doesn't stream it here.")
                .font(AetherDesign.Typography.caption)
                .foregroundStyle(AetherDesign.Palette.textTertiary)
        }
        // On tvOS a Netflix-only detail has no launch button (`canLaunch` is
        // false there), so this block is pure text — and a pushed screen with
        // NOTHING focusable traps the user: the system reads Back/Menu as
        // "exit app" instead of "pop" (#377). Make the block self-focus when
        // there's no button, mirroring AetherEmptyState/AetherErrorState. A
        // no-op elsewhere, where `canLaunch` is true and the button takes focus.
        .focusable(!NetflixLauncher.canLaunch)
    }

}
