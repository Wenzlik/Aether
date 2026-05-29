import SwiftUI
import AVKit
import AetherCore

struct PlayerView: View {
    let item: MediaItem
    let onDismiss: () -> Void
    @State private var viewModel: PlayerStateViewModel

    /// Chrome auto-hide window. Lines up with `AVPlayerViewController`'s
    /// native transport bar so the overlay xmark on iOS / visionOS feels
    /// like part of the system chrome rather than a separate always-visible
    /// surface.
    private static let chromeIdleHide: Duration = .seconds(3)

    #if os(iOS) || os(visionOS)
    @State private var isCloseVisible = true
    @State private var hideTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #endif

    init(item: MediaItem, session: PlaybackSession, onDismiss: @escaping () -> Void) {
        self.item = item
        self.onDismiss = onDismiss
        _viewModel = State(initialValue: PlayerStateViewModel(session: session))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player = viewModel.player {
                SystemVideoPlayer(player: player) {
                    Task { await dismissPlayer() }
                }
                .ignoresSafeArea()
            } else if viewModel.state.status == .failed {
                playbackUnavailable
            } else {
                ProgressView()
                    .tint(AetherDesign.Palette.textPrimary)
            }

            #if os(iOS) || os(visionOS)
            closeButton
                .opacity(isCloseVisible ? 1 : 0)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.25),
                    value: isCloseVisible
                )
                .allowsHitTesting(isCloseVisible)
            #endif
            // tvOS routes dismiss through the native chrome's `Done`
            // contextual action and the Menu button on the Siri Remote
            // (`.onExitCommand` below). No SwiftUI overlay there.
        }
        #if os(iOS) || os(visionOS)
        // `simultaneousGesture` keeps AVPlayer's own tap-to-toggle-chrome
        // intact while letting us mirror its visibility on the overlay
        // xmark. Without the simultaneous variant, our tap would consume
        // the touch and the native transport bar would stop responding.
        .simultaneousGesture(
            TapGesture().onEnded { revealChrome() }
        )
        #endif
        .task {
            await viewModel.open(item)
            #if os(iOS) || os(visionOS)
            scheduleChromeHide()
            #endif
        }
        .onDisappear {
            Task { await viewModel.close() }
            #if os(iOS) || os(visionOS)
            hideTask?.cancel()
            #endif
        }
        #if os(tvOS)
        .onExitCommand { Task { await dismissPlayer() } }
        #endif
    }

    #if os(iOS) || os(visionOS)
    private var closeButton: some View {
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
                .accessibilityLabel("Close player")
                Spacer()
            }
            Spacer()
        }
    }

    private func revealChrome() {
        isCloseVisible = true
        scheduleChromeHide()
    }

    private func scheduleChromeHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: Self.chromeIdleHide)
            guard !Task.isCancelled else { return }
            isCloseVisible = false
        }
    }
    #endif

    private func dismissPlayer() async {
        // Pause first so audio stops on the same frame the fade begins.
        await viewModel.pause()
        onDismiss()
    }

    private var playbackUnavailable: some View {
        AetherErrorState(
            glyph: "play.slash",
            title: "Playback unavailable",
            message: "This title isn't streamable yet."
        )
        .padding(AetherDesign.Spacing.xl)
    }
}
