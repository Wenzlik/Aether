import SwiftUI
import AVKit
import AetherCore

struct PlayerView: View {
    let item: MediaItem
    let onDismiss: () -> Void
    @State private var viewModel: PlayerStateViewModel

    init(item: MediaItem, session: PlaybackSession, onDismiss: @escaping () -> Void) {
        self.item = item
        self.onDismiss = onDismiss
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
                        Task { await dismissPlayer() }
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
            // tvOS deliberately has no custom close chrome — the Menu button on
            // the Siri Remote triggers `.onExitCommand` below, which dismisses
            // via the same path. Adding tap-target close UI on tvOS would fight
            // the focus model (see AGENTS.md → tvOS rules).
        }
        .task { await viewModel.open(item) }
        .onDisappear { Task { await viewModel.close() } }
        #if os(tvOS)
        .onExitCommand { Task { await dismissPlayer() } }
        #endif
    }

    private func dismissPlayer() async {
        // Pause first so audio stops on the same frame the fade begins.
        await viewModel.pause()
        onDismiss()
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
