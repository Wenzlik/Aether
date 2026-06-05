import SwiftUI
import AetherCore

struct DetailView: View {
    let item: MediaItem
    let source: (any MediaSource)?
    let resumeStore: ResumeStore
    let playbackSession: PlaybackSession
    /// `nil` until `AppSession.start()` has booted the downloads pipeline.
    /// Views guard with `if let manager` so a pre-boot Detail still works
    /// (Play / Resume) — just no Download button.
    let downloadManager: DownloadManager?
    /// `@MainActor`-bound mirror of the store. Reads
    /// `downloads.snapshot.status(for:)` synchronously in `body`. `nil`
    /// until boot completes for the same reason as `downloadManager`.
    let downloads: DownloadObserver?
    /// App-wide playback defaults (Default Quality / Audio Language /
    /// Subtitle Language). When the user opens a title, the Audio /
    /// Subtitles / Quality pickers pre-select matching values from these
    /// defaults so playback starts how the user said they want it.
    /// `nil` only in test fixtures or pre-boot paths.
    let playbackPreferences: PlaybackPreferencesStore?

    @State private var resume: ResumePoint?
    @State private var isPlayerPresented = false
    @State private var playbackItem: MediaItem?
    /// Where the presented player should begin. `nil` resumes from the saved
    /// point ("Resume"); `0` forces a restart ("Play From Beginning").
    @State private var playbackStartAt: Double?
    @State private var isPreparingPlayback = false
    /// visionOS: the current player presentation was launched via "Watch in
    /// Cinema" → auto-expand so it docks into the Dark Theater without a tap.
    @State private var launchingInCinema = false
    @State private var children: [MediaItem] = []
    @State private var isLoadingChildren = false
    /// The item with full metadata (audio + subtitle streams, partID,
    /// mediaInfo) once hydrated, carrying the user's audio / subtitle / quality
    /// choices. Playback decisions happen here on Detail, before the player
    /// opens — the configured item is what launches. `nil` until the detail
    /// endpoint resolves; `current` falls back to the list `item`.
    @State private var configuredItem: MediaItem?
    /// Which compact selector sheet is currently presented on Detail. `nil`
    /// = nothing open; tapping a disclosure row sets one. iOS / iPadOS uses
    /// `.presentationDetents([.medium])` so the picker takes about half the
    /// screen and the Detail backdrop is still visible behind.
    @State private var presentedSelector: PlaybackSelector?
    /// True while a Download is being prepared (quality picker → enqueue) so
    /// the button can read "Starting…" and disable.
    @State private var isEnqueuingDownload = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Drives the backdrop layout: compact (iPhone) → full-width 16:9; regular
    /// (iPad / tvOS / visionOS) → edge-to-edge fill at a fixed height.
    @Environment(\.horizontalSizeClass) private var hSizeClass
    #if os(visionOS)
    /// Cinema Mode state — drives the "Watch in Cinema" entry. Injected at the
    /// app root; always present inside the windowed view tree on visionOS.
    @Environment(CinemaManager.self) private var cinema
    #endif

    /// Which selector sheet is open. Audio / Subtitles / Quality are the
    /// playback configuration triplet; `downloadQuality` reuses the same
    /// sheet pattern but enqueues a download instead of recording a
    /// selection on the item.
    private enum PlaybackSelector: Identifiable {
        case audio, subtitles, quality, downloadQuality
        var id: String {
            switch self {
            case .audio: return "audio"
            case .subtitles: return "subtitles"
            case .quality: return "quality"
            case .downloadQuality: return "downloadQuality"
            }
        }
    }

    /// The item reflecting hydration + the user's track / quality selections.
    private var current: MediaItem { configuredItem ?? item }

    /// Download status for this item. `.notDownloaded` when the pipeline
    /// hasn't booted yet — same surface as "no job recorded" so the UI
    /// renders identically.
    private var downloadStatus: DownloadStatus {
        downloads?.status(for: item.id) ?? .notDownloaded
    }

    var body: some View {
        ZStack {
            scrollContent
                .opacity(isPlayerPresented ? 0 : 1)

            if isPlayerPresented {
                PlayerView(
                    item: playbackItem ?? item,
                    source: source,
                    session: playbackSession,
                    startAt: playbackStartAt,
                    preferExpanded: launchingInCinema,
                    onDismiss: dismissPlayer
                )
                .transition(.opacity)
                .zIndex(10)
                #if os(iOS)
                .statusBarHidden()
                #endif
            }
        }
        .background(AetherDesign.Palette.background.ignoresSafeArea())
        #if os(iOS)
        .toolbar(isPlayerPresented ? .hidden : .automatic, for: .navigationBar)
        #endif
        .toolbar(isPlayerPresented ? .hidden : .automatic, for: .tabBar)
        .task {
            resume = await resumeStore.point(for: item.id)
            await hydrateForPlayback()
            await loadChildrenIfNeeded()
        }
        .animation(reduceMotion ? nil : AetherDesign.Motion.hero, value: isPlayerPresented)
        .sheet(item: $presentedSelector) { selector in
            // Use the closure parameter, not the @State again. On first
            // presentation SwiftUI evaluates the sheet body before the
            // @State write has propagated through, so reading
            // `presentedSelector` inside `playbackSelectorSheet` hits
            // the stale `nil` value, the switch falls into `case .none`,
            // and the user sees an empty sheet. Reopening works because
            // by then @State is settled. The closure parameter is the
            // snapshot at presentation — always non-nil, always
            // correct.
            playbackSelectorSheet(for: selector)
        }
        #if os(visionOS)
        .onChange(of: cinema.isActive) { _, active in
            // Cinema ended (movie finished or the Dark Theater was dismissed) —
            // drop the player overlay so we don't leave a stale player behind.
            guard !active, isPlayerPresented else { return }
            withAnimation(reduceMotion ? nil : AetherDesign.Motion.hero) {
                isPlayerPresented = false
            }
            playbackItem = nil
            Task { resume = await resumeStore.point(for: item.id) }
        }
        #endif
    }

    // MARK: - Detail content

    private var scrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                // Hero: edge-to-edge backdrop with the title + metadata + badges
                // stacked *below* it (not overlaid), so wide layouts don't push
                // the text into a side gutter beside a letterboxed image.
                VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
                    BackdropImage(
                        url: item.backdropURL ?? item.posterURL,
                        height: hSizeClass == .regular ? backdropMaxHeight : nil
                    )

                    VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
                        Text(item.title)
                            .font(AetherDesign.Typography.heroTitle)
                            .foregroundStyle(AetherDesign.Palette.textPrimary)
                        metadataRow
                        mediaBadges
                    }
                    .padding(.horizontal, AetherDesign.Spacing.l)
                }

                // Layout order (Apple-TV / Infuse style): Hero → Actions →
                // Playback → Overview → Media Information → (children).
                if !item.kind.isContainer {
                    actionRow
                        .padding(.horizontal, AetherDesign.Spacing.l)
                }

                if !item.kind.isContainer, current.streamURL != nil {
                    playbackSection
                        .padding(.horizontal, AetherDesign.Spacing.l)
                        .frame(maxWidth: 720, alignment: .leading)
                }

                if let summary = item.summary {
                    Text(summary)
                        .font(AetherDesign.Typography.body)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                        .padding(.horizontal, AetherDesign.Spacing.l)
                        .frame(maxWidth: 720, alignment: .leading)
                }

                if !item.kind.isContainer, current.mediaInfo != nil {
                    mediaSection
                        .padding(.horizontal, AetherDesign.Spacing.l)
                        .frame(maxWidth: 720, alignment: .leading)
                }

                if item.kind.isContainer {
                    childrenSection
                        .padding(.horizontal, AetherDesign.Spacing.l)
                }
            }
            .padding(.bottom, AetherDesign.Spacing.xxl)
        }
    }

    private var backdropMaxHeight: CGFloat {
        #if os(tvOS)
        560
        #else
        420
        #endif
    }

    // MARK: - Children (seasons / episodes)

    @ViewBuilder
    private var childrenSection: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            Text(childrenTitle)
                .font(AetherDesign.Typography.sectionTitle)
                .foregroundStyle(AetherDesign.Palette.textPrimary)

            if isLoadingChildren {
                AetherLoadingState(.inline)
            } else if children.isEmpty {
                Text("Nothing here yet.")
                    .font(AetherDesign.Typography.body)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
            } else if item.kind == .show {
                seasonsRail
            } else {
                episodesList
            }
        }
    }

    private var childrenTitle: String {
        item.kind == .show ? "Seasons" : "Episodes"
    }

    private var seasonsRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: AetherDesign.Spacing.m) {
                ForEach(children) { season in
                    NavigationLink(value: season) {
                        AetherCard.poster(title: season.title, posterURL: season.posterURL)
                            .frame(width: 140)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, AetherDesign.Spacing.xs)
        }
    }

    private var episodesList: some View {
        LazyVStack(spacing: AetherDesign.Spacing.m) {
            ForEach(children) { episode in
                NavigationLink(value: episode) {
                    episodeRow(episode)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func episodeRow(_ episode: MediaItem) -> some View {
        HStack(alignment: .top, spacing: AetherDesign.Spacing.m) {
            CachedAsyncImage(url: episode.backdropURL ?? episode.posterURL, aspectRatio: 16.0 / 9.0)
                .frame(width: 150)
                .clipShape(RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous))

            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xxs) {
                Text(episode.title)
                    .font(AetherDesign.Typography.cardTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                    .lineLimit(2)
                if let runtime = episode.runtime {
                    Text(formatRuntime(runtime))
                        .font(AetherDesign.Typography.caption)
                        .foregroundStyle(AetherDesign.Palette.textTertiary)
                }
                if let summary = episode.summary {
                    Text(summary)
                        .font(AetherDesign.Typography.caption)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func loadChildrenIfNeeded() async {
        guard item.kind.isContainer, let source, children.isEmpty else { return }
        isLoadingChildren = true
        defer { isLoadingChildren = false }
        do {
            children = try await source.children(of: item.id)
        } catch {
            children = []
        }
    }

    private var metadataRow: some View {
        HStack(spacing: AetherDesign.Spacing.s) {
            if let year = item.year {
                Text(String(year))
            }
            if let runtime = item.runtime {
                Text(formatRuntime(runtime))
            }
            Text(kindLabel(item.kind))
                .foregroundStyle(AetherDesign.Palette.textTertiary)
            Spacer(minLength: 0)
        }
        .font(AetherDesign.Typography.metadata)
        .foregroundStyle(AetherDesign.Palette.textSecondary)
    }

    /// Compact technical chips under the metadata — resolution, HDR / Dolby
    /// Vision, video codec, audio. Quality at a glance instead of buried in a
    /// table. Only shown once `MediaInfo` is hydrated.
    @ViewBuilder
    private var mediaBadges: some View {
        let labels = mediaBadgeLabels
        if !labels.isEmpty {
            HStack(spacing: AetherDesign.Spacing.xs) {
                ForEach(labels, id: \.self) { AetherBadge($0) }
            }
            .padding(.top, AetherDesign.Spacing.xxs)
        }
    }

    private var mediaBadgeLabels: [String] {
        guard let info = current.mediaInfo else { return [] }
        var labels: [String] = []
        if let resolution = info.videoResolution { labels.append(resolution) }
        if info.isDolbyVision {
            labels.append("Dolby Vision")
        } else if info.isHDR {
            labels.append("HDR")
        }
        if let codec = info.videoCodec?.uppercased() { labels.append(codec) }
        if let audio = info.audioCodec?.uppercased() {
            if let channels = info.audioChannels {
                labels.append("\(audio) \(channelLabel(channels))")
            } else {
                labels.append(audio)
            }
        }
        return labels
    }

    // MARK: - Action row (Resume / Play From Beginning / Play, or unavailable)

    @ViewBuilder
    private var actionRow: some View {
        if current.streamURL != nil {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
                if resume != nil {
                    resumeButtons
                } else {
                    playButton
                }
                #if os(visionOS)
                watchInCinemaButton
                #endif
                if shouldShowDownloadControl {
                    downloadControl
                }
            }
        } else {
            unavailableState
        }
    }

    /// True when a Download surface should appear below the play buttons —
    /// only for Plex / Jellyfin items (the only sources that implement
    /// `downloadURL`), and only once the pipeline has booted.
    private var shouldShowDownloadControl: Bool {
        guard downloadManager != nil, source?.supportsDownloads == true else { return false }
        return true
    }

    /// The state-driven Download surface. Renders as a primary "Download"
    /// button when nothing's recorded; otherwise morphs into a disclosure
    /// row that shows the current status and acts as the primary in-line
    /// action for that state (Pause / Resume / Delete / Retry).
    @ViewBuilder
    private var downloadControl: some View {
        switch downloadStatus {
        case .notDownloaded:
            AetherButton(
                isEnqueuingDownload ? "Starting…" : "Download",
                systemImage: "arrow.down.circle",
                role: .secondary
            ) {
                presentedSelector = .downloadQuality
            }
            .disabled(isEnqueuingDownload)

        case .queued:
            downloadStatusRow(
                value: "Queued",
                actionLabel: "Cancel"
            ) { Task { await cancelDownload() } }

        case let .downloading(fraction):
            downloadStatusRow(
                value: "Downloading · \(percentString(fraction))",
                actionLabel: "Pause"
            ) { Task { await pauseDownload() } }

        case let .paused(fraction):
            downloadStatusRow(
                value: "Paused at \(percentString(fraction))",
                actionLabel: "Resume"
            ) { Task { await resumeDownload() } }

        case let .completed(_, size):
            downloadStatusRow(
                value: "Downloaded · \(formatBytes(size))",
                actionLabel: "Delete"
            ) { Task { await removeDownload() } }

        case let .failed(reason):
            downloadStatusRow(
                value: "Failed · \(reason)",
                actionLabel: "Retry"
            ) { Task { await retryDownload() } }

        case .expired:
            downloadStatusRow(
                value: "Expired",
                actionLabel: "Re-download"
            ) { Task { await retryDownload() } }
        }
    }

    /// One-row layout: status text on the left, single trailing action on
    /// the right. Each transient download state collapses to this so
    /// the row's geometry doesn't shift as progress ticks.
    private func downloadStatusRow(
        value: String,
        actionLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: AetherDesign.Spacing.m) {
            Image(systemName: "arrow.down.circle.fill")
                .font(AetherDesign.Typography.body)
                .foregroundStyle(AetherDesign.Palette.accent)
                .frame(width: 28)
            Text(value)
                .font(AetherDesign.Typography.body)
                .foregroundStyle(AetherDesign.Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: AetherDesign.Spacing.s)
            Button(actionLabel, action: action)
                .buttonStyle(.plain)
                .font(AetherDesign.Typography.metadata)
                .foregroundStyle(AetherDesign.Palette.accent)
        }
        .padding(.vertical, AetherDesign.Spacing.m)
        .padding(.horizontal, AetherDesign.Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                .fill(AetherDesign.Materials.card)
        )
    }

    /// "47%" — keeps the row stable as progress ticks (no decimals,
    /// always two digits at most).
    private func percentString(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

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
    /// Resumes from the saved point when one exists, else starts from the top,
    /// matching the Play / Resume button above it.
    private var watchInCinemaButton: some View {
        AetherButton(
            "Watch in Cinema",
            systemImage: "visionpro",
            role: .secondary
        ) {
            Task { await watchInCinema() }
        }
        .disabled(isPreparingPlayback)
    }
    #endif

    /// Resume exists: **Resume** (primary, with a resume-from caption) and
    /// **Restart** (secondary) sitting side-by-side, each expanding to
    /// equal width. "Restart" is the Apple-TV-app's name for the same
    /// action — short enough to fit alongside Resume on iPhone without
    /// the row wrapping to two lines. The "Resume from 1:23" caption
    /// stays beneath the row, leading-aligned, so it pairs with Resume
    /// (which is on the left).
    private var resumeButtons: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
            HStack(spacing: AetherDesign.Spacing.s) {
                AetherButton(
                    isPreparingPlayback ? "Preparing…" : "Resume",
                    systemImage: "play.fill",
                    role: .primary
                ) {
                    Task { await presentPlayer(fromStart: false) }
                }
                .frame(maxWidth: .infinity)
                .disabled(isPreparingPlayback)

                AetherButton(
                    "Restart",
                    systemImage: "backward.end.fill",
                    role: .secondary
                ) {
                    Task { await presentPlayer(fromStart: true) }
                }
                .frame(maxWidth: .infinity)
                .disabled(isPreparingPlayback)
            }

            Text("Resume from \(formatPosition(resume?.position ?? .zero))")
                .font(AetherDesign.Typography.caption)
                .foregroundStyle(AetherDesign.Palette.textSecondary)
                .padding(.leading, AetherDesign.Spacing.xs)
        }
    }

    private var unavailableState: some View {
        AetherErrorState(
            glyph: "play.slash",
            title: "Playback unavailable",
            message: "This title isn't streamable yet. If it's a format Plex can't direct-play, transcode support lands in a future update."
        )
        .padding(.top, -AetherDesign.Spacing.xxl)
    }

    // MARK: - Playback options (compact selectors + media info)

    /// Compact Audio / Subtitles / Quality rows. Each row shows the current
    /// selection in muted text and a chevron; tap opens a bottom sheet.
    private var playbackSection: some View {
        AetherSettingsSection("Playback") {
            if !current.audioTracks.isEmpty {
                AetherDisclosureRow(
                    label: "Audio",
                    value: current.selectedAudioTrack?.displayTitle
                ) {
                    presentedSelector = .audio
                }
            }
            if !current.subtitleTracks.isEmpty {
                AetherDisclosureRow(
                    label: "Subtitles",
                    value: current.selectedSubtitleTrack?.displayTitle ?? "Off"
                ) {
                    presentedSelector = .subtitles
                }
            }
            AetherDisclosureRow(
                label: "Quality",
                value: qualityRowValue
            ) {
                presentedSelector = .quality
            }
        }
    }

    /// "Original · Direct Play" / "Convert Automatically" / "8 Mbps 1080p"
    /// — the chosen quality plus a hint at the projected playback mode for
    /// Original (Direct Play if container is AVPlayer-friendly, else
    /// Direct Stream). Other qualities just show their label.
    private var qualityRowValue: String {
        switch current.selectedQuality {
        case .original:
            switch projectedPlaybackMode {
            case .directPlay:   return "Original · Direct Play"
            case .directStream: return "Original · Direct Stream"
            case .transcode:    return "Original"
            }
        default:
            return current.selectedQuality.displayName
        }
    }

    /// The bottom sheet behind the disclosure rows. Half-height on iOS,
    /// full modal on tvOS / visionOS. Takes the `selector` as a
    /// parameter (passed by `.sheet(item:)` at presentation time) so it
    /// always renders the right content — see the comment at the
    /// `.sheet` call site for why reading `presentedSelector` directly
    /// here was the source of the "empty sheet on first open" bug.
    @ViewBuilder
    private func playbackSelectorSheet(for selector: PlaybackSelector) -> some View {
        switch selector {
        case .audio:
            playbackSelectorContent(title: "Audio") {
                audioSelectorList
            }
        case .subtitles:
            playbackSelectorContent(title: "Subtitles") {
                subtitleSelectorList
            }
        case .quality:
            playbackSelectorContent(title: "Quality") {
                qualitySelectorList
            }
        case .downloadQuality:
            playbackSelectorContent(title: "Download Quality") {
                downloadQualitySelectorList
            }
        }
    }

    /// The sheet body: a calm header + the option list, on the same dark
    /// background the rest of the app uses (the system sheet chrome handles
    /// the "card on top of detail" affordance).
    @ViewBuilder
    private func playbackSelectorContent<Content: View>(
        title: String,
        @ViewBuilder list: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                Text(title)
                    .font(AetherDesign.Typography.sectionTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                    .padding(.horizontal, AetherDesign.Spacing.l)
                    .padding(.top, AetherDesign.Spacing.l)

                VStack(spacing: 0) {
                    list()
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

    private var audioSelectorList: some View {
        ForEach(current.audioTracks) { track in
            AetherSelectionRow(
                title: track.displayTitle,
                isSelected: track.id == current.selectedAudioTrackID
            ) {
                configuredItem = current.selectingAudioTrack(track)
                presentedSelector = nil
            }
        }
    }

    private var subtitleSelectorList: some View {
        Group {
            AetherSelectionRow(
                title: "Off",
                isSelected: current.selectedSubtitleTrackID == nil
            ) {
                configuredItem = current.selectingSubtitleTrack(nil)
                presentedSelector = nil
            }
            ForEach(current.subtitleTracks) { track in
                AetherSelectionRow(
                    title: track.displayTitle,
                    isSelected: track.id == current.selectedSubtitleTrackID
                ) {
                    configuredItem = current.selectingSubtitleTrack(track)
                    presentedSelector = nil
                }
            }
        }
    }

    private var qualitySelectorList: some View {
        ForEach(PlaybackQuality.allCases, id: \.self) { quality in
            AetherSelectionRow(
                title: quality.displayName,
                isSelected: quality == current.selectedQuality
            ) {
                configuredItem = current.selectingQuality(quality)
                presentedSelector = nil
            }
        }
    }

    /// Quality picker for the **Download** path. Same options as
    /// `qualitySelectorList`, different action: pick → close sheet →
    /// enqueue download with that quality. No selection state to
    /// "remember" — the user picks once per download, and the choice is
    /// recorded on the `DownloadJob`.
    private var downloadQualitySelectorList: some View {
        ForEach(PlaybackQuality.allCases, id: \.self) { quality in
            AetherSelectionRow(
                title: quality.displayName,
                isSelected: false
            ) {
                presentedSelector = nil
                Task { await startDownload(quality: quality) }
            }
        }
    }

    // MARK: - Download actions

    private func startDownload(quality: PlaybackQuality) async {
        guard let manager = downloadManager, let source else { return }
        isEnqueuingDownload = true
        defer { isEnqueuingDownload = false }
        do {
            _ = try await manager.enqueue(item: current, source: source, quality: quality)
        } catch {
            // Surface failure via the row's next render (DownloadStatus
            // moves to .failed in the store) — no toast / alert chrome
            // for Phase 2.1.
        }
    }

    private func pauseDownload() async {
        guard let manager = downloadManager,
              let job = downloads?.job(for: item.id) else { return }
        await manager.pause(job.id)
    }

    private func resumeDownload() async {
        guard let manager = downloadManager,
              let job = downloads?.job(for: item.id) else { return }
        await manager.resume(job.id)
    }

    private func cancelDownload() async {
        guard let manager = downloadManager,
              let job = downloads?.job(for: item.id) else { return }
        await manager.cancel(job.id)
    }

    private func removeDownload() async {
        guard let manager = downloadManager,
              let job = downloads?.job(for: item.id) else { return }
        await manager.remove(job.id)
    }

    /// Retry path: drop the existing record + start a fresh enqueue at
    /// the same quality. Cleaner than trying to in-place revive a
    /// `.failed` URLSession task (URLSession's resumeData for that task
    /// is gone by then).
    private func retryDownload() async {
        guard let manager = downloadManager,
              let source,
              let job = downloads?.job(for: item.id) else { return }
        let quality = job.quality
        await manager.remove(job.id)
        do {
            _ = try await manager.enqueue(item: current, source: source, quality: quality)
        } catch {
            // Same swallow as `startDownload` — store status will reflect.
        }
    }

    /// Source media info + projected playback mode. The codecs / bitrate /
    /// resolution come from Plex metadata as the file is on disk; the
    /// "Playback" line is a best-effort guess based on container + quality.
    /// The server's actual decision is taken when Play is pressed.
    @ViewBuilder
    private var mediaSection: some View {
        let info = current.mediaInfo
        AetherSettingsSection("Media Information") {
            if let video = videoLine(info) {
                AetherSettingsRow(label: "Video", value: video)
            }
            if let audio = audioLine(info) {
                AetherSettingsRow(label: "Audio", value: audio)
            }
            if let bitrate = info?.bitrateKbps {
                AetherSettingsRow(label: "Bitrate", value: formatBitrate(bitrate))
            }
            if let hdrBadge = hdrBadge(info) {
                AetherSettingsRow(label: "HDR", value: hdrBadge)
            }
            AetherSettingsRow(label: "Playback", status: playbackModeStatus)
            if let source {
                AetherSettingsRow(label: "Source", value: source.displayName)
            }
        }
    }

    private func videoLine(_ info: MediaInfo?) -> String? {
        guard let info else { return nil }
        let codec = info.videoCodec?.uppercased()
        let resolution = info.videoResolution
        switch (codec, resolution) {
        case let (codec?, resolution?): return "\(codec) \(resolution)"
        case let (codec?, nil):         return codec
        case let (nil, resolution?):    return resolution
        case (nil, nil):                return nil
        }
    }

    private func audioLine(_ info: MediaInfo?) -> String? {
        guard let info else { return nil }
        let codec = info.audioCodec?.uppercased()
        let channels = info.audioChannels.map { channelLabel($0) }
        switch (codec, channels) {
        case let (codec?, channels?): return "\(codec) \(channels)"
        case let (codec?, nil):       return codec
        case let (nil, channels?):    return channels
        case (nil, nil):              return nil
        }
    }

    /// Plex's channel count → loudspeaker layout label: 2 → "2.0", 6 → "5.1",
    /// 8 → "7.1". Anything we don't recognise falls back to "N ch".
    private func channelLabel(_ channels: Int) -> String {
        switch channels {
        case 1: return "Mono"
        case 2: return "2.0"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(channels) ch"
        }
    }

    private func hdrBadge(_ info: MediaInfo?) -> String? {
        guard let info else { return nil }
        if info.isDolbyVision { return "Dolby Vision" }
        if info.isHDR { return "HDR" }
        return nil
    }

    private func formatBitrate(_ kbps: Int) -> String {
        if kbps >= 1000 {
            let mbps = Double(kbps) / 1000.0
            return String(format: "%.1f Mbps", mbps)
        }
        return "\(kbps) kbps"
    }

    /// Best-effort projected playback mode for the Media line, computed from
    /// container + quality choice. The server's actual decision is taken when
    /// Play is pressed; this is just a hint so the user knows what'll happen.
    private var playbackModeStatus: AetherStatus {
        let mode = projectedPlaybackMode
        switch mode {
        case .directPlay:   return .positive(mode.displayName)
        case .directStream: return .positive(mode.displayName)
        case .transcode:    return .muted(mode.displayName)
        }
    }

    private var projectedPlaybackMode: PlaybackDecisionMode {
        let container = current.mediaInfo?.container?.lowercased()
        let directPlayContainers: Set<String> = ["mp4", "m4v", "mov"]
        switch current.selectedQuality {
        case .original:
            if let container, directPlayContainers.contains(container) {
                return .directPlay
            }
            return .directStream
        case .convertAutomatically:
            return .directStream
        case .bitrate20Mbps1080p, .bitrate12Mbps1080p, .bitrate8Mbps1080p,
             .bitrate4Mbps720p, .bitrate2Mbps720p, .bitrate720kbps:
            return .transcode
        }
    }

    private func hydrateForPlayback() async {
        guard !item.kind.isContainer, let source else { return }
        if let hydrated = try? await source.item(for: item.id) {
            configuredItem = applyingPreferences(to: hydrated)
        }
    }

    /// Seeds the user's app-wide playback defaults onto a freshly hydrated
    /// item. Each preference is applied only when it points at a track that
    /// actually exists on the title — a Czech-audio default doesn't force
    /// English-only content into silence — and only when set; `nil` means
    /// "follow the source default" and falls through to whatever the source
    /// (Plex / Jellyfin) already picked. The user's per-title picker tap
    /// later still wins for that session.
    private func applyingPreferences(to hydrated: MediaItem) -> MediaItem {
        guard let prefs = playbackPreferences else { return hydrated }
        var result = hydrated

        // Audio: match by language code (case-insensitive). Only override
        // when the title has a track in the preferred language.
        if let preferred = prefs.defaultAudioLanguage?.lowercased(),
           let track = result.audioTracks.first(where: {
               $0.languageCode?.lowercased() == preferred
           }) {
            result = result.selectingAudioTrack(track)
        }

        // Subtitles: "off" disables subs entirely; nil leaves whatever the
        // source picked; a language code selects the first matching track.
        if let preferred = prefs.defaultSubtitleLanguage {
            if preferred == "off" {
                result = result.selectingSubtitleTrack(nil)
            } else if let track = result.subtitleTracks.first(where: {
                $0.languageCode?.lowercased() == preferred.lowercased()
            }) {
                result = result.selectingSubtitleTrack(track)
            }
        }

        // Quality: always applied. The MediaItem default is `.original`,
        // but most users want the picker to open on whatever they chose
        // last as their everywhere-default.
        result = result.selectingQuality(prefs.defaultQuality)

        return result
    }

    // MARK: - Player dismiss

    private func presentPlayer(fromStart: Bool) async {
        guard !isPreparingPlayback else { return }
        isPreparingPlayback = true
        defer { isPreparingPlayback = false }

        // `current` is already hydrated (on appear) and carries the user's
        // audio + subtitle + quality choices, so the player launches exactly
        // what the Detail screen showed. Fall back to a fresh hydrate if it
        // somehow hasn't resolved yet.
        if configuredItem == nil, let source, let hydrated = try? await source.item(for: item.id) {
            configuredItem = hydrated
        }
        playbackItem = current

        // `0` forces a restart; `nil` lets the session resume from the
        // persisted point.
        playbackStartAt = fromStart ? 0 : nil
        launchingInCinema = false   // windowed playback stays embedded

        withAnimation(reduceMotion ? nil : AetherDesign.Motion.hero) {
            isPlayerPresented = true
        }
    }

    private func dismissPlayer() {
        withAnimation(reduceMotion ? nil : AetherDesign.Motion.hero) {
            isPlayerPresented = false
        }
        playbackItem = nil
        #if os(visionOS)
        // No-op unless this was a cinema session; tears down the Dark Theater.
        cinema.end()
        #endif
        Task { resume = await resumeStore.point(for: item.id) }
    }

    #if os(visionOS)
    /// Enter Cinema Mode: present the native player (same `PlayerView` /
    /// `AVPlayerViewController` as windowed playback) **and** ask `CinemaManager`
    /// to open the Dark Theater. The system then docks the fullscreen player
    /// into the immersive space — native controls, native sizing. `nil` startAt
    /// resumes from the saved point, mirroring the Resume button.
    private func watchInCinema() async {
        guard !isPreparingPlayback else { return }
        isPreparingPlayback = true
        defer { isPreparingPlayback = false }

        if configuredItem == nil, let source, let hydrated = try? await source.item(for: item.id) {
            configuredItem = hydrated
        }
        playbackItem = current
        playbackStartAt = resume != nil ? nil : 0
        launchingInCinema = true   // auto-expand so it docks into the theater
        cinema.present(current, source: source, startAt: playbackStartAt)
        withAnimation(reduceMotion ? nil : AetherDesign.Motion.hero) {
            isPlayerPresented = true
        }
    }
    #endif

    // MARK: - Formatting helpers

    private func kindLabel(_ kind: MediaItem.Kind) -> String {
        switch kind {
        case .movie: return "Movie"
        case .episode: return "Episode"
        case .show: return "Series"
        case .season: return "Season"
        }
    }

    private func formatRuntime(_ duration: Duration) -> String {
        let total = Int(durationSeconds(duration))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private func formatPosition(_ duration: Duration) -> String {
        let total = Int(durationSeconds(duration))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func durationSeconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
