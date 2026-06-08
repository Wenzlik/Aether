import SwiftUI
import AVFoundation
import AetherCore

/// The branded loading animation — the looping Aether logo video
/// (`AetherLoading.mp4`), muted and controls-less. Shown while content is
/// loading or a refresh is resolving, in place of the old skeleton rails.
struct AetherVideoLoader: View {
    var caption: String?

    var body: some View {
        VStack(spacing: AetherDesign.Spacing.l) {
            LoopingVideoPlayer(resource: "AetherLoading", fileExtension: "mp4")
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: 460)
                .accessibilityHidden(true)
            if let caption {
                Text(caption)
                    .font(AetherDesign.Typography.metadata)
                    .foregroundStyle(AetherDesign.Palette.textSecondary)
                    .accessibilityLabel(Text(caption))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// A muted, seamlessly-looping, controls-less video backed by `AVPlayerLayer` +
/// `AVPlayerLooper`. Plays while on screen; stops on teardown. Available on every
/// shipped platform (AVKit/UIKit). If the resource is missing it renders empty
/// rather than crashing.
private struct LoopingVideoPlayer: UIViewRepresentable {
    let resource: String
    let fileExtension: String

    func makeUIView(context: Context) -> LoopingPlayerUIView {
        LoopingPlayerUIView(resource: resource, fileExtension: fileExtension)
    }

    func updateUIView(_ uiView: LoopingPlayerUIView, context: Context) {}

    static func dismantleUIView(_ uiView: LoopingPlayerUIView, coordinator: ()) {
        uiView.stop()
    }
}

final class LoopingPlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    private let queuePlayer = AVQueuePlayer()
    private var looper: AVPlayerLooper?

    private var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }

    init(resource: String, fileExtension: String) {
        super.init(frame: .zero)
        backgroundColor = .clear
        playerLayer?.videoGravity = .resizeAspect
        playerLayer?.player = queuePlayer
        // The loop is purely decorative — muted, so it never interrupts other
        // audio or grabs the session (it has no audio track anyway).
        queuePlayer.isMuted = true

        guard let url = Bundle.main.url(forResource: resource, withExtension: fileExtension) else { return }
        let item = AVPlayerItem(url: url)
        looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        queuePlayer.play()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func stop() {
        queuePlayer.pause()
        queuePlayer.removeAllItems()
        looper?.disableLooping()
    }
}

/// Wraps a state view (loading / empty / error) so it (1) fills the screen and
/// centers, and (2) lives inside a bouncing `ScrollView` — so the screen's
/// `.refreshable` works even when there's no content yet. Previously these
/// states were content-sized (the gradient showed as a band) and not scrollable
/// (pull-to-refresh couldn't reach them, so an empty/error state got stuck).
struct AetherCenteredScrollState<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                content()
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .center)
            }
            #if !os(tvOS)
            // Always bounce so pull-to-refresh fires even when the content fits.
            .scrollBounceBehavior(.always)
            #endif
        }
    }
}
