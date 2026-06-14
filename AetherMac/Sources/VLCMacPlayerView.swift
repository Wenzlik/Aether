import SwiftUI
import VLCKit

/// The video surface. **Must be a `VLCVideoView`**, not a plain `NSView`:
/// VLCKit's macOS video output renders into the `VLCVideoView`/`VLCVideoLayer`
/// it sets up itself (correct GL pixel format + CAOpenGLLayer). Handing it a
/// bare `NSView` made the GL vout assert (`GL_INVALID_OPERATION` in
/// `CreateFilters`) on first frame.
private struct VLCVideoSurface: NSViewRepresentable {
    let model: MacPlayerModel
    func makeNSView(context: Context) -> VLCDrawableView {
        let surface = VLCDrawableView()
        surface.backColor = .black
        model.player.drawable = surface
        // Start playback only once the view is in a window (GL framebuffer ready).
        surface.onAttached = { [model] in model.markViewReady() }
        return surface
    }
    func updateNSView(_ nsView: VLCDrawableView, context: Context) {}
}

/// `VLCVideoView` that reports when it's attached to a window — VLCKit's GL
/// context/framebuffer only becomes valid then, so the player must not `play()`
/// before this fires (racing it asserted GL_INVALID_FRAMEBUFFER_OPERATION).
private final class VLCDrawableView: VLCVideoView {
    var onAttached: (@MainActor () -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onAttached?() }
    }
}

/// IINA-style **VLCKit** player — the fallback engine for containers/codecs
/// AVFoundation can't open (mkv, DTS, …). Full-bleed video with an auto-hiding
/// floating control bar (scrub, ±10s, play/pause, time, volume, audio/subtitle
/// menus, full-screen) and keyboard shortcuts (space, ←/→). Native formats go
/// to `AVKitPlayerScreen` instead — see `MacPlayerView`.
struct VLCPlayerScreen: View {
    let url: URL
    @State private var model = MacPlayerModel()
    @State private var controlsVisible = true
    @State private var hideWorkItem: DispatchWorkItem?

    var body: some View {
        @Bindable var model = model
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            VLCVideoSurface(model: model).ignoresSafeArea()

            if controlsVisible {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    controlBar(model)
                }
                .transition(.opacity)
            }
        }
        .onAppear { model.load(url); scheduleHide() }
        .onDisappear { model.stop() }
        .onChange(of: url) { _, newURL in model.load(newURL) }
        .contentShape(Rectangle())
        // Double-click toggles full-screen (standard player gesture).
        .onTapGesture(count: 2) { NSApp.keyWindow?.toggleFullScreen(nil) }
        .onContinuousHover { phase in
            switch phase {
            case .active: reveal()
            case .ended:  break
            }
        }
        .background(keyboardShortcuts(model))
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        .navigationTitle(model.title)
    }

    // MARK: Chrome

    private func controlBar(_ model: MacPlayerModel) -> some View {
        @Bindable var model = model
        return VStack(spacing: 10) {
            // Scrubber + time
            HStack(spacing: 12) {
                Text(model.timeText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Slider(value: $model.position, in: 0...1) { editing in
                    model.isScrubbing = editing
                    if !editing { model.commitSeek() }
                }
                Text(model.durationText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }

            HStack(spacing: 18) {
                transportButton("gobackward.10") { model.skipBackward() }
                transportButton(model.isPlaying ? "pause.fill" : "play.fill", size: 26) { model.togglePlay() }
                transportButton("goforward.10") { model.skipForward() }

                Spacer()

                // Volume
                HStack(spacing: 6) {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: $model.volume, in: 0...100).frame(width: 90)
                }

                trackMenu(systemImage: "waveform", tracks: model.audioTracks, currentID: model.currentAudioID) { model.selectAudio(id: $0) }
                trackMenu(systemImage: "captions.bubble", tracks: model.subtitleTracks, currentID: model.currentSubtitleID) { model.selectSubtitle(id: $0) }

                transportButton("arrow.up.left.and.arrow.down.right") {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
            }
        }
        .padding(20)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(20)
        .frame(maxWidth: 900)
    }

    private func transportButton(_ symbol: String, size: CGFloat = 18, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .medium))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func trackMenu(
        systemImage: String,
        tracks: [TrackOption],
        currentID: Int,
        select: @escaping (Int) -> Void
    ) -> some View {
        Menu {
            // VLCKit 3 already includes a "Disable" entry (id -1) in the list, so
            // no separate Off button is needed.
            ForEach(tracks) { track in
                Button {
                    select(track.id)
                } label: {
                    if track.id == currentID {
                        Label(track.name, systemImage: "checkmark")
                    } else {
                        Text(track.name)
                    }
                }
            }
        } label: {
            Image(systemName: systemImage)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(tracks.isEmpty)
    }

    // MARK: Keyboard

    private func keyboardShortcuts(_ model: MacPlayerModel) -> some View {
        ZStack {
            Button("") { model.togglePlay() }.keyboardShortcut(.space, modifiers: [])
            Button("") { model.skipBackward() }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { model.skipForward() }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { NSApp.keyWindow?.toggleFullScreen(nil) }.keyboardShortcut("f", modifiers: [])
        }
        .opacity(0)
    }

    // MARK: Auto-hide

    private func reveal() {
        if !controlsVisible { controlsVisible = true }
        scheduleHide()
    }

    private func scheduleHide() {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { controlsVisible = false }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
}
