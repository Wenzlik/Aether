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
                SystemVideoPlayer(player: player)
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
            #if os(iOS)
            // iOS only: schedule the auto-hide so the xmark mirrors
            // AVKit's transport bar. visionOS keeps the close button
            // permanently visible (see `effectiveCloseVisibility`) —
            // gaze + pinch on the player area doesn't reliably reach our
            // `simultaneousGesture` past AVPlayerViewController's own
            // gesture stack, so an auto-hidden button there strands the
            // user mid-playback.
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
    /// playback is actually live, **and only on iOS**. visionOS keeps the
    /// close button permanently visible: a gaze + pinch tap against the
    /// player area doesn't reliably reach our SwiftUI `simultaneousGesture`
    /// (AVPlayerViewController's UIKit gesture stack tends to swallow it),
    /// so auto-hiding the xmark there strands users mid-playback.
    private var effectiveCloseVisibility: Bool {
        #if os(visionOS)
        return true
        #else
        guard viewModel.state.status != .failed else { return true }
        guard viewModel.player != nil else { return true }
        return isCloseVisible
        #endif
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
                        .font(.system(size: closeGlyphPointSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(closeButtonInnerPadding)
                        // `contentShape(Circle())` guarantees the hit-test
                        // area matches the visible button. Without it, the
                        // ultraThinMaterial background isn't always honoured
                        // for hit testing, and the button feels "dead" in a
                        // few pixel rings around the glyph.
                        .background(.ultraThinMaterial, in: Circle())
                        .contentShape(Circle())
                }
                .padding(AetherDesign.Spacing.m)
                .accessibilityLabel("Close player")
                // visionOS-only hint: tells the system this is an
                // interactive element so the gaze-driven hover effect lights
                // it up. Without `.hoverEffect`, visionOS sometimes doesn't
                // route a pinch on a small SwiftUI button that sits over an
                // AVPlayerViewController to our handler — the button looks
                // like decoration, the gaze passes through to the player
                // chrome behind it, and the user can't dismiss.
                #if os(visionOS)
                .hoverEffect()
                #endif
                Spacer()
            }
            Spacer()
        }
    }

    /// Glyph size for the close button. visionOS needs a larger target
    /// because the user "taps" by gazing at it and pinching — a small
    /// iOS-sized button is hard to acquire.
    private var closeGlyphPointSize: CGFloat {
        #if os(visionOS)
        return 24
        #else
        return 18
        #endif
    }

    private var closeButtonInnerPadding: CGFloat {
        #if os(visionOS)
        return AetherDesign.Spacing.m
        #else
        return AetherDesign.Spacing.s
        #endif
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
