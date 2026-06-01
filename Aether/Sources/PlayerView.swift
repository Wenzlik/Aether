import SwiftUI
import AVKit
import AetherCore

struct PlayerView: View {
    let item: MediaItem
    /// Where playback should begin. `nil` resumes from the persisted point;
    /// `0` (or any explicit value) starts there, ignoring the saved resume.
    let startAt: Double?
    let onDismiss: () -> Void
    @State private var viewModel: PlayerStateViewModel

    /// Chrome auto-hide window. Lines up with `AVPlayerViewController`'s
    /// native transport bar so the overlay close affordance feels
    /// like part of the system chrome rather than a separate always-visible
    /// surface.
    private static let chromeIdleHide: Duration = .seconds(3)

    #if os(iOS) || os(visionOS)
    @State private var isCloseVisible = true
    @State private var hideTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #endif

    init(
        item: MediaItem,
        session: PlaybackSession,
        startAt: Double? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.item = item
        self.startAt = startAt
        self.onDismiss = onDismiss
        _viewModel = State(initialValue: PlayerStateViewModel(session: session))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if viewModel.state.status == .failed {
                playbackUnavailable
            } else if let player = viewModel.player {
                SystemVideoPlayer(
                    player: player,
                    onDismiss: {
                        Task { await dismissPlayer() }
                    }
                )
                #if os(visionOS)
                .safeAreaPadding(.top, AetherDesign.Spacing.l)
                #else
                .ignoresSafeArea()
                #endif
            } else {
                ProgressView()
                    .tint(AetherDesign.Palette.textPrimary)
            }

            #if os(iOS) || os(visionOS)
            playerChrome
                .zIndex(20)
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
        // intact while letting us mirror its visibility on the overlay close
        // button. Without the simultaneous variant, our tap would consume the
        // touch and the native transport bar would stop responding.
        .simultaneousGesture(
            TapGesture().onEnded { revealChrome() }
        )
        #endif
        .task {
            await viewModel.open(item, startAt: startAt)
            #if os(iOS) || os(visionOS)
            // Schedule the auto-hide so our chrome (iOS xmark, visionOS audio
            // menu) mirrors AVKit's transport bar instead of sitting over the
            // video permanently. A tap (`revealChrome`) brings it back.
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
    /// Chrome visibility that respects the auto-hide timer while playback is
    /// actually live. The chrome (audio-track menu on visionOS, plus the close
    /// xmark on iOS) fades out a few seconds after the last interaction and a
    /// tap reveals it again — mirroring AVKit's own transport bar so it doesn't
    /// sit on top of the video the whole time. Always visible while loading or
    /// on failure so the user is never stranded without a control.
    private var effectiveCloseVisibility: Bool {
        guard viewModel.state.status != .failed else { return true }
        guard viewModel.player != nil else { return true }
        return isCloseVisible
    }
    #endif

    #if os(iOS) || os(visionOS)
    private var playerChrome: some View {
        VStack {
            HStack {
                // iOS only. visionOS dismisses through the native AVKit
                // `Back` contextual action (see `SystemVideoPlayer`): it's the
                // reliable escape hatch when `AVPlayerViewController` owns the
                // gaze / pinch routing, and a second SwiftUI chevron here just
                // duplicated both it and the system window ornament.
                #if os(iOS)
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
                .accessibilityLabel("Close player")
                #endif

                Spacer()

                if audioTracks.count > 1 {
                    audioTrackMenu
                }
            }
            .padding(AetherDesign.Spacing.m)
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

    private var audioTracks: [MediaAudioTrack] {
        viewModel.state.item?.audioTracks ?? item.audioTracks
    }

    private var selectedAudioTrackID: String? {
        viewModel.state.item?.selectedAudioTrackID ?? item.selectedAudioTrackID
    }

    private var audioTrackMenu: some View {
        Menu {
            ForEach(audioTracks) { track in
                Button {
                    revealChrome()
                    Task { await viewModel.selectAudioTrack(track) }
                } label: {
                    Label(
                        track.displayTitle,
                        systemImage: track.id == selectedAudioTrackID ? "checkmark" : "speaker.wave.2"
                    )
                }
            }
        } label: {
            Image(systemName: "speaker.wave.2")
                .font(.system(size: closeGlyphPointSize, weight: .semibold))
                .foregroundStyle(.white)
                .padding(closeButtonInnerPadding)
                .background(.ultraThinMaterial, in: Circle())
                .contentShape(Circle())
        }
        .accessibilityLabel("Audio track")
        #if os(visionOS)
        .hoverEffect()
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
