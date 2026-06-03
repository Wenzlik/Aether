import SwiftUI
import AetherCore

struct DetailView: View {
    let item: MediaItem
    let source: (any MediaSource)?
    let resumeStore: ResumeStore
    let playbackSession: PlaybackSession

    @State private var resume: ResumePoint?
    @State private var isPlayerPresented = false
    @State private var playbackItem: MediaItem?
    /// Where the presented player should begin. `nil` resumes from the saved
    /// point ("Resume"); `0` forces a restart ("Play From Beginning").
    @State private var playbackStartAt: Double?
    @State private var isPreparingPlayback = false
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Which playback option is being changed by the user right now.
    private enum PlaybackSelector: Identifiable {
        case audio, subtitles, quality
        var id: String {
            switch self {
            case .audio: return "audio"
            case .subtitles: return "subtitles"
            case .quality: return "quality"
            }
        }
    }

    /// The item reflecting hydration + the user's track / quality selections.
    private var current: MediaItem { configuredItem ?? item }

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
        .sheet(item: $presentedSelector) { _ in
            playbackSelectorSheet
        }
    }

    // MARK: - Detail content

    private var scrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                BackdropImage(url: item.backdropURL ?? item.posterURL)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: backdropMaxHeight)
                    .clipped()
                    .overlay(alignment: .bottomLeading) {
                        VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
                            Text(item.title)
                                .font(AetherDesign.Typography.heroTitle)
                                .foregroundStyle(AetherDesign.Palette.textPrimary)
                            metadataRow
                        }
                        .padding(AetherDesign.Spacing.l)
                        .padding(.bottom, AetherDesign.Spacing.s)
                    }

                if !item.kind.isContainer {
                    actionRow
                        .padding(.horizontal, AetherDesign.Spacing.l)
                }

                if let summary = item.summary {
                    Text(summary)
                        .font(AetherDesign.Typography.body)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                        .padding(.horizontal, AetherDesign.Spacing.l)
                        .frame(maxWidth: 720, alignment: .leading)
                }

                if !item.kind.isContainer, current.streamURL != nil {
                    playbackOptions
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

    // MARK: - Action row (Resume / Play From Beginning / Play, or unavailable)

    @ViewBuilder
    private var actionRow: some View {
        if current.streamURL != nil {
            if resume != nil {
                resumeButtons
            } else {
                playButton
            }
        } else {
            unavailableState
        }
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

    /// Resume exists: Resume (primary, with a resume-from caption) plus Play
    /// From Beginning (secondary). Resume uses Plex's stored `viewOffset`.
    private var resumeButtons: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
                AetherButton(
                    isPreparingPlayback ? "Preparing…" : "Resume",
                    systemImage: "play.fill",
                    role: .primary
                ) {
                    Task { await presentPlayer(fromStart: false) }
                }
                .disabled(isPreparingPlayback)

                Text("Resume from \(formatPosition(resume?.position ?? .zero))")
                    .font(AetherDesign.Typography.caption)
                    .foregroundStyle(AetherDesign.Palette.textSecondary)
                    .padding(.leading, AetherDesign.Spacing.xs)
            }

            AetherButton(
                "Play From Beginning",
                systemImage: "backward.end.fill",
                role: .secondary
            ) {
                Task { await presentPlayer(fromStart: true) }
            }
            .disabled(isPreparingPlayback)
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

    /// Everything the user can see and change *before* pressing Play.
    ///
    /// Audio / Subtitles / Quality each collapse to a single `AetherDisclosureRow`
    /// showing the current choice; tapping opens a bottom-sheet picker that
    /// reuses `AetherSelectionRow` for the option list. This keeps the long
    /// Detail screen calm even for items with many audio / subtitle tracks
    /// and an eight-step quality ladder.
    ///
    /// The Media section stays expanded — it's read-only info about the source
    /// file (codecs, resolution, bitrate, HDR badge) plus the projected
    /// playback mode.
    @ViewBuilder
    private var playbackOptions: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
            playbackSection
            mediaSection
        }
    }

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

    /// The bottom sheet behind the disclosure rows. Half-height on iOS, full
    /// modal on tvOS / visionOS. Driven by `presentedSelector`.
    private var playbackSelectorSheet: some View {
        Group {
            switch presentedSelector {
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
            case .none:
                EmptyView()
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

    /// Source media info + projected playback mode. The codecs / bitrate /
    /// resolution come from Plex metadata as the file is on disk; the
    /// "Playback" line is a best-effort guess based on container + quality.
    /// The server's actual decision is taken when Play is pressed.
    @ViewBuilder
    private var mediaSection: some View {
        let info = current.mediaInfo
        AetherSettingsSection("Media") {
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
            configuredItem = hydrated
        }
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

        withAnimation(reduceMotion ? nil : AetherDesign.Motion.hero) {
            isPlayerPresented = true
        }
    }

    private func dismissPlayer() {
        withAnimation(reduceMotion ? nil : AetherDesign.Motion.hero) {
            isPlayerPresented = false
        }
        playbackItem = nil
        Task { resume = await resumeStore.point(for: item.id) }
    }

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
