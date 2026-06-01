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

            if viewModel.state.status == .failed {
                playbackUnavailable
            } else if let player = viewModel.player {
                SystemVideoPlayer(player: player) {
                    Task { await dismissPlayer() }
                }
                .ignoresSafeArea()
            } else {
                ProgressView()
                    .tint(AetherDesign.Palette.textPrimary)
            }

            #if os(iOS) || os(visionOS)
            closeButton
                .opacity(effectiveCloseVisibility ? 1 : 0)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.25),
                    value: effectiveCloseVisibility
                )
                .allowsHitTesting(effectiveCloseVisibility)
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
            // Schedule the auto-hide only if we actually have an active
            // player to hide chrome over. Loading / failed states keep the
            // close button up via `effectiveCloseVisibility` so the user
            // is never stranded without a dismiss path — the visionOS
            // window has no system back gesture wired to a ZStack overlay,
            // so this is the only way out.
            if viewModel.player != nil {
                scheduleChromeHide()
            }
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
    /// Chrome visibility that respects the auto-hide timer **only** while
    /// playback is actually live. With no `player` (loading, failed, or any
    /// non-playing state) the close button stays on screen forever so the
    /// user can always exit — particularly important on visionOS, where a
    /// ZStack overlay has no system back gesture to fall back on.
    private var effectiveCloseVisibility: Bool {
        guard viewModel.state.status != .failed else { return true }
        guard viewModel.player != nil else { return true }
        return isCloseVisible
    }
    #endif

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
            message: failureDiagnostic,
            retry: .init(label: "Close player") {
                Task { await dismissPlayer() }
            }
        )
        .padding(AetherDesign.Spacing.xl)
    }

    /// Surface the underlying reason so we can tell, in TestFlight on a real
    /// device, *why* playback failed: missing stream URL, AVPlayer network /
    /// codec / TLS failure (with domain + code), or something stranger.
    /// Intentionally noisy until playback is reliable on every platform —
    /// tighten to a single sentence once visionOS is stable.
    private var failureDiagnostic: String {
        let state = viewModel.state
        guard let item = state.item else {
            return "No item — the player opened without a title attached."
        }
        var parts: [String] = []
        parts.append("\(item.title) (\(item.kind))")
        if let url = item.streamURL {
            parts.append("URL host: \(url.host ?? "?")")
            parts.append("scheme: \(url.scheme ?? "?")")
        } else {
            parts.append("Stream URL is missing.")
        }
        if let error = state.error {
            parts.append(error)
        }
        return parts.joined(separator: " · ")
    }
}
