import SwiftUI
import AetherCore

struct DetailView: View {
    let item: MediaItem
    let resumeStore: ResumeStore
    let playbackSession: PlaybackSession

    @State private var resume: ResumePoint?
    @State private var isPlayerPresented = false
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
        .task { resume = await resumeStore.point(for: item.id) }
        .animation(reduceMotion ? nil : AetherDesign.Motion.hero, value: isPlayerPresented)
    }

    // MARK: - Detail content

    private var scrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                BackdropImage(url: item.backdropURL ?? item.posterURL)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 360)
                    .clipped()
                    .overlay(alignment: .bottomLeading) {
                        Text(item.title)
                            .font(AetherDesign.Typography.heroTitle)
                            .foregroundStyle(AetherDesign.Palette.textPrimary)
                            .padding(AetherDesign.Spacing.l)
                    }

                metadataRow
                    .padding(.horizontal, AetherDesign.Spacing.l)

                if let summary = item.summary {
                    Text(summary)
                        .font(AetherDesign.Typography.body)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                        .padding(.horizontal, AetherDesign.Spacing.l)
                }

                actionRow
                    .padding(.horizontal, AetherDesign.Spacing.l)
            }
            .padding(.vertical, AetherDesign.Spacing.l)
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
        Button {
            withAnimation(reduceMotion ? nil : AetherDesign.Motion.hero) {
                isPlayerPresented = true
            }
        } label: {
            PlayButtonLabel(text: resume.map { "Resume \(formatPosition($0.position))" } ?? "Play")
        }
        .buttonStyle(.plain)
    }

    private var unavailableState: some View {
        HStack(alignment: .firstTextBaseline, spacing: AetherDesign.Spacing.s) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(AetherDesign.Palette.textTertiary)
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xxs) {
                Text("Unavailable")
                    .font(AetherDesign.Typography.cardTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                Text("This item doesn't have a stream URL yet.")
                    .font(AetherDesign.Typography.body)
                    .foregroundStyle(AetherDesign.Palette.textSecondary)
            }
        }
        .padding(AetherDesign.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AetherDesign.Palette.surface, in: RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous))
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

/// The label shown inside the Play / Resume button.
///
/// On tvOS, reads `\.isFocused` and lifts on focus. On iOS the focused state
/// collapses since there's no focus engine.
private struct PlayButtonLabel: View {
    let text: String
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: AetherDesign.Spacing.xs) {
            Image(systemName: "play.fill")
            Text(text)
        }
        .font(AetherDesign.Typography.cardTitle)
        .padding(.horizontal, AetherDesign.Spacing.l)
        .padding(.vertical, AetherDesign.Spacing.s)
        .background(
            AetherDesign.Palette.accent.opacity(isFocused ? 0.40 : 0.20),
            in: Capsule()
        )
        .foregroundStyle(AetherDesign.Palette.textPrimary)
        .shadow(color: .black.opacity(isFocused ? 0.40 : 0.0),
                radius: isFocused ? 16 : 0,
                y: isFocused ? 8 : 0)
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .animation(AetherDesign.Motion.focus, value: isFocused)
    }
}
