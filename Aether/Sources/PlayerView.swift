import SwiftUI
import AVKit
import AetherCore

struct PlayerView: View {
    let item: MediaItem
    let resumeStore: ResumeStore

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onAppear { player.play() }
                    .onDisappear {
                        player.pause()
                        Task { await persistResume(from: player) }
                    }
            } else {
                ProgressView()
                    .tint(AetherDesign.Palette.textPrimary)
            }

            #if os(iOS)
            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(AetherDesign.Spacing.s)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .padding(AetherDesign.Spacing.m)
                    Spacer()
                }
                Spacer()
            }
            #endif
        }
        .task { await prepare() }
    }

    private func prepare() async {
        guard let url = item.streamURL else { return }
        let avPlayer = AVPlayer(url: url)

        if let existing = await resumeStore.point(for: item.id) {
            let cmTime = CMTime(seconds: durationSeconds(existing.position), preferredTimescale: 600)
            await avPlayer.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        player = avPlayer
    }

    @MainActor
    private func persistResume(from player: AVPlayer) async {
        let cmTime = player.currentTime()
        guard cmTime.isValid && !cmTime.seconds.isNaN else { return }
        let position = Duration.seconds(cmTime.seconds)
        await resumeStore.record(ResumePoint(mediaID: item.id, position: position))
    }

    private func durationSeconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
