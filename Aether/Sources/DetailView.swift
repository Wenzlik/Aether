import SwiftUI
import AetherCore

struct DetailView: View {
    let item: MediaItem
    let source: (any MediaSource)?
    let resumeStore: ResumeStore
    let playbackSession: PlaybackSession

    @State private var resume: ResumePoint?
    @State private var isPlayerPresented = false
    @State private var children: [MediaItem] = []
    @State private var isLoadingChildren = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            scrollContent
                .opacity(isPlayerPresented ? 0 : 1)

            if isPlayerPresented {
                PlayerView(
                    item: item,
                    session: playbackSession,
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
        .task {
            resume = await resumeStore.point(for: item.id)
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

    // MARK: - Action row (Play, or unavailable empty state)

    @ViewBuilder
    private var actionRow: some View {
        if item.streamURL != nil {
            playButton
        } else {
            unavailableState
        }
    }

    private var playButton: some View {
        AetherButton(
            playButtonLabel,
            systemImage: "play.fill",
            role: .primary
        ) {
            withAnimation(reduceMotion ? nil : AetherDesign.Motion.hero) {
                isPlayerPresented = true
            }
        }
    }

    private var playButtonLabel: String {
        if let resume { return "Resume \(formatPosition(resume.position))" }
        return "Play"
    }

    private var unavailableState: some View {
        AetherErrorState(
            glyph: "play.slash",
            title: "Playback unavailable",
            message: "This title isn't streamable yet. If it's a format Plex can't direct-play, transcode support lands in a future update."
        )
        .padding(.top, -AetherDesign.Spacing.xxl)
    }

    // MARK: - Player dismiss

    private func dismissPlayer() {
        withAnimation(reduceMotion ? nil : AetherDesign.Motion.hero) {
            isPlayerPresented = false
        }
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
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func durationSeconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

