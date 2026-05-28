import SwiftUI
import AetherCore

struct DetailView: View {
    let item: MediaItem
    let resumeStore: ResumeStore
    let playbackSession: PlaybackSession

    @State private var resume: ResumePoint?
    @State private var isPlayerPresented = false

    var body: some View {
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

                playButton
                    .padding(.horizontal, AetherDesign.Spacing.l)
            }
            .padding(.vertical, AetherDesign.Spacing.l)
        }
        .background(AetherDesign.Palette.background.ignoresSafeArea())
        .task { resume = await resumeStore.point(for: item.id) }
        .fullScreenCover(
            isPresented: $isPlayerPresented,
            onDismiss: {
                // Refresh the resume display after the player closes — the session
                // wrote the latest position during playback.
                Task { resume = await resumeStore.point(for: item.id) }
            }
        ) {
            PlayerView(item: item, session: playbackSession)
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

    private var playButton: some View {
        Button {
            isPlayerPresented = true
        } label: {
            HStack(spacing: AetherDesign.Spacing.xs) {
                Image(systemName: "play.fill")
                if let resume {
                    Text("Resume \(formatPosition(resume.position))")
                } else {
                    Text("Play")
                }
            }
            .font(AetherDesign.Typography.cardTitle)
            .padding(.horizontal, AetherDesign.Spacing.l)
            .padding(.vertical, AetherDesign.Spacing.s)
            .background(AetherDesign.Palette.accent.opacity(0.20), in: Capsule())
            .foregroundStyle(AetherDesign.Palette.textPrimary)
        }
        .buttonStyle(.plain)
        .disabled(item.streamURL == nil)
    }

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
