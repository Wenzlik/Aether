import SwiftUI
import AVKit
import AetherCore

struct PlayerView: View {
    let item: MediaItem
    @State private var viewModel: PlayerStateViewModel

    @Environment(\.dismiss) private var dismiss

    init(item: MediaItem, session: PlaybackSession) {
        self.item = item
        _viewModel = State(initialValue: PlayerStateViewModel(session: session))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player = viewModel.player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else if viewModel.state.status == .failed {
                playbackUnavailable
            } else {
                ProgressView()
                    .tint(AetherDesign.Palette.textPrimary)
            }

            #if os(iOS)
            VStack {
                HStack {
                    Button {
                        Task { await viewModel.close() }
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
        .task { await viewModel.open(item) }
        .onDisappear { Task { await viewModel.close() } }
    }

    private var playbackUnavailable: some View {
        VStack(spacing: AetherDesign.Spacing.s) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(AetherDesign.Palette.textSecondary)
            Text("Playback unavailable")
                .font(AetherDesign.Typography.sectionTitle)
                .foregroundStyle(AetherDesign.Palette.textPrimary)
            Text("This item has no stream URL.")
                .font(AetherDesign.Typography.body)
                .foregroundStyle(AetherDesign.Palette.textSecondary)
        }
        .padding(AetherDesign.Spacing.xl)
    }
}
