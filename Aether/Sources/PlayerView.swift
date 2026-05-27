import SwiftUI
import AVKit
import AetherCore

struct PlayerView: View {
    let item: MediaItem

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onAppear { player.play() }
                    .onDisappear { player.pause() }
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
        .onAppear {
            if let url = item.streamURL {
                player = AVPlayer(url: url)
            }
        }
    }
}
