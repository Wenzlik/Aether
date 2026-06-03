#if os(visionOS)
import SwiftUI
import RealityKit
import AVFoundation
import AetherCore

/// Cinema Mode's immersive scene — the **second renderer** of the one
/// `PlaybackSession` (the first being the windowed `AVPlayerViewController`).
///
/// It opens the exact same item through the exact same `PlayerStateViewModel`
/// the windowed player uses, then renders the vended `AVPlayer` on a RealityKit
/// screen via **`VideoPlayerComponent`** (clean playback incl. HDR; a
/// `VideoMaterial` plane scrambled this content on device).
///
/// **Sizing:** uniform `scale`, capped at ≤ 1.0. `VideoPlayerComponent` renders
/// cleanly at or below its native size but breaks when scaled *up* (artefacts,
/// black screen) — so Wall is native size and the smaller presets scale down.
/// The screen sits against the back wall with its **bottom edge anchored to the
/// violet accent line** (measured from the rendered height), so it reads as
/// mounted, rising from the line.
///
/// **Controls:** `VideoPlayerComponent`'s native transport doesn't surface
/// reliably here, so the glass panel carries the full transport itself; there's
/// no native bar to double with.
///
/// The playback engine is untouched (see `docs/next-steps/visionos-cinema.md`
/// → §0). On entry the main app window is dismissed; on exit it's reopened.
struct CinemaImmersiveView: View {
    let session: PlaybackSession
    @Bindable var cinema: CinemaCoordinator

    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var viewModel: PlayerStateViewModel
    @State private var screen = Entity()
    @State private var boundPlayerID: ObjectIdentifier?
    /// The item currently configured for playback; changes on an in-cinema
    /// audio / subtitle / quality pick (which re-resolves at the position).
    @State private var playing: MediaItem?

    private static let controlsPosition = SIMD3<Float>(0, 1.05, -1.3)
    /// Height of the Dark Theater's violet accent line — the screen's bottom
    /// edge anchors here, so the screen rises from the line / floor.
    private static let lineY: Float = 0.05
    /// Fixed render scale. `VideoPlayerComponent` renders cleanly around here
    /// but breaks when scaled much higher (~5 = artefacts, more = black), so we
    /// hold scale fixed and vary *apparent* size by distance (which never
    /// breaks rendering) instead of by scaling up.
    private static let screenScale: Float = 2.5

    init(session: PlaybackSession, cinema: CinemaCoordinator) {
        self.session = session
        self.cinema = cinema
        _viewModel = State(initialValue: PlayerStateViewModel(session: session))
    }

    private var activeItem: MediaItem? {
        playing ?? cinema.item
    }

    var body: some View {
        RealityView { content, attachments in
            content.add(CinemaTheater.makeEntity(for: cinema.environment))
            content.add(screen)
            if let controls = attachments.entity(for: "controls") {
                controls.position = Self.controlsPosition
                content.add(controls)
            }
        } update: { _, _ in
            applyScreenLayout()
        } attachments: {
            Attachment(id: "controls") {
                let item = activeItem
                CinemaControlsView(
                    viewModel: viewModel,
                    cinema: cinema,
                    item: item,
                    onSelectAudio: { track in
                        if let item { reconfigure(item.selectingAudioTrack(track)) }
                    },
                    onSelectSubtitle: { track in
                        if let item { reconfigure(item.selectingSubtitleTrack(track)) }
                    },
                    onSelectQuality: { quality in
                        if let item { reconfigure(item.selectingQuality(quality)) }
                    },
                    onLeave: { leaveCinema() }
                )
            }
        }
        .task {
            guard let item = cinema.item else { return }
            playing = item
            await viewModel.open(item, source: cinema.source, startAt: cinema.startAt)
            bindScreenIfNeeded()
            await settleScreenLayout()
            dismissWindow(id: CinemaCoordinator.mainWindowID)
        }
        .onChange(of: playerIdentity) {
            bindScreenIfNeeded()
        }
        .onChange(of: cinema.screenPreset) {
            applyScreenLayout()
        }
        .onDisappear {
            openWindow(id: CinemaCoordinator.mainWindowID)
            cinema.didLeave()
            Task { await viewModel.close() }
        }
    }

    // MARK: - Exit

    private func leaveCinema() {
        Task { await dismissImmersiveSpace() }
    }

    // MARK: - Screen binding + layout

    private var playerIdentity: ObjectIdentifier? {
        viewModel.player.map(ObjectIdentifier.init)
    }

    private func bindScreenIfNeeded() {
        guard let player = viewModel.player else { return }
        let id = ObjectIdentifier(player)
        guard boundPlayerID != id else { return }
        boundPlayerID = id
        screen.components.set(VideoPlayerComponent(avPlayer: player))
        applyScreenLayout()
    }

    /// Place the screen: fixed render scale, bottom edge anchored to the violet
    /// line (from the measured rendered height), and **distance** chosen by the
    /// preset — closer reads as bigger. Distance is the size lever because
    /// scaling `VideoPlayerComponent` up breaks its rendering.
    private func applyScreenLayout() {
        guard boundPlayerID != nil else { return }
        screen.scale = SIMD3(repeating: Self.screenScale)

        let height = screen.visualBounds(relativeTo: nil).extents.y
        let centreY: Float = height > 0.01 ? Self.lineY + height / 2 : 1.6
        screen.position = [0, centreY, Self.screenDistance(for: cinema.screenPreset)]
    }

    /// Re-apply once the screen's rendered bounds are available (the component
    /// reports them a moment after binding), so the bottom-edge anchor lands.
    private func settleScreenLayout() async {
        for _ in 0..<15 {
            applyScreenLayout()
            if screen.visualBounds(relativeTo: nil).extents.y > 0.01 {
                applyScreenLayout()
                break
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    /// Per-preset viewing distance (metres, negative = in front). Closer reads
    /// as bigger. This is the size control instead of scale. First pass —
    /// adjust on device.
    private static func screenDistance(for preset: CinemaScreenPreset) -> Float {
        switch preset {
        case .medium: return -5.0
        case .large:  return -3.9
        case .imax:   return -2.9
        case .wall:   return -2.1
        }
    }

    // MARK: - Reconfiguration (in-cinema track / quality change)

    private func reconfigure(_ newItem: MediaItem) {
        playing = newItem
        let position = seconds(viewModel.state.position)
        Task {
            await viewModel.open(newItem, source: cinema.source, startAt: position > 1 ? position : 0)
            bindScreenIfNeeded()
            await settleScreenLayout()
        }
    }

    private func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
#endif
