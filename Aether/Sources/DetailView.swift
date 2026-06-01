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
    /// point ("Continue Watching"); `0` forces a restart ("Play From Beginning").
    @State private var playbackStartAt: Double?
    @State private var isPreparingPlayback = false
    @State private var children: [MediaItem] = []
    @State private var isLoadingChildren = false
    /// The item with full metadata (audio + subtitle streams) once hydrated,
    /// carrying the user's audio/subtitle choices. Playback decisions happen
    /// here on Detail, before the player opens — the configured item is what
    /// launches. `nil` until the detail endpoint resolves; `current` falls back
    /// to the list `item` so direct-play titles still play.
    @State private var configuredItem: MediaItem?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The item reflecting hydration + the user's track selections.
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
        // iOS only. The player overlays this view *inside* the NavigationStack
        // and on iPhone / iPad the nav bar's back button would otherwise sit
        // behind / above the video — looks like junk, so we hide it for the
        // duration of playback. The player's own overlay xmark is the dismiss
        // surface on iOS.
        //
        // visionOS is **excluded on purpose.** Hiding the toolbar there leaves
        // the system back chevron rendered in the window's ornament bar but
        // non-functional — taps fire haptic feedback (we saw
        // `MRUIFeedbackTypeButtonWithoutBackgroundTouchDown` timeouts in the
        // logs) without actually popping the NavigationStack. Keeping the
        // toolbar visible during playback makes the chevron behave normally:
        // tap → pop DetailView → PlayerView's `.onDisappear` writes the
        // resume point and tears down → user lands back on Home. The small
        // strip of window chrome over the player is an acceptable price for
        // a functional native back gesture.
        .toolbar(isPlayerPresented ? .hidden : .automatic, for: .navigationBar)
        #endif
        .task {
            resume = await resumeStore.point(for: item.id)
            await hydrateForPlayback()
            await loadChildrenIfNeeded()
        }
        .animation(reduceMotion ? nil : AetherDesign.Motion.hero, value: isPlayerPresented)
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

    // MARK: - Action row (Continue Watching / Play, or unavailable state)

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

    /// Resume exists: Continue Watching (primary, with a resume-from caption)
    /// plus Play From Beginning (secondary).
    private var resumeButtons: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
                AetherButton(
                    isPreparingPlayback ? "Preparing…" : "Continue Watching",
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

    // MARK: - Playback options (audio / subtitles / source / quality)

    /// Everything the user can see and change *before* pressing Play. The
    /// selected audio + subtitle tracks are always visible, so it's clear what
    /// will play. Source + quality are informational (display only). Track
    /// lists appear only for transcode titles, which is where Aether can act on
    /// the selection — direct-play falls back to AVKit's own picker in-player.
    @ViewBuilder
    private var playbackOptions: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
            if !current.audioTracks.isEmpty {
                AetherSettingsSection("Audio") {
                    ForEach(current.audioTracks) { track in
                        AetherSelectionRow(
                            title: track.displayTitle,
                            isSelected: track.id == current.selectedAudioTrackID
                        ) {
                            configuredItem = current.selectingAudioTrack(track)
                        }
                    }
                }
            }

            if !current.subtitleTracks.isEmpty {
                AetherSettingsSection("Subtitles") {
                    AetherSelectionRow(
                        title: "Off",
                        isSelected: current.selectedSubtitleTrackID == nil
                    ) {
                        configuredItem = current.selectingSubtitleTrack(nil)
                    }
                    ForEach(current.subtitleTracks) { track in
                        AetherSelectionRow(
                            title: track.displayTitle,
                            isSelected: track.id == current.selectedSubtitleTrackID
                        ) {
                            configuredItem = current.selectingSubtitleTrack(track)
                        }
                    }
                }
            }

            AetherSettingsSection("Playback") {
                if let source {
                    AetherSettingsRow(label: "Source", value: source.displayName)
                }
                AetherSettingsRow(label: "Quality", status: qualityStatus)
            }
        }
    }

    private var qualityStatus: AetherStatus {
        current.isServerTranscode ? .muted("Transcoding") : .positive("Direct Play")
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
        // audio + subtitle choices, so the player launches exactly what the
        // Detail screen showed. Fall back to a fresh hydrate if it somehow
        // hasn't resolved yet.
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
