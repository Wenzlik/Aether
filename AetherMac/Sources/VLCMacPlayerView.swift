import SwiftUI
import VLCKit

/// The video surface — an `NSView` VLCKit renders into, bound to the model's
/// player. The system window frames it (resize / full-screen / ⌘W are free).
private struct VLCVideoSurface: NSViewRepresentable {
    let model: MacPlayerModel
    func makeNSView(context: Context) -> NSView {
        let surface = NSView()
        surface.wantsLayer = true
        surface.layer?.backgroundColor = NSColor.black.cgColor
        model.player.drawable = surface
        return surface
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
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
                    titleBar
                    Spacer(minLength: 0)
                    controlBar(model)
                }
                .transition(.opacity)
            }
        }
        .onAppear { model.load(url); scheduleHide() }
        .onChange(of: url) { _, newURL in model.load(newURL) }
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

    private var titleBar: some View {
        HStack {
            Text(model.title)
                .font(.headline)
                .foregroundStyle(.white)
                .shadow(radius: 4)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
        )
    }

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

                trackMenu(systemImage: "waveform", tracks: model.audioTracks, includeOff: false) { model.selectAudio($0!) }
                trackMenu(systemImage: "captions.bubble", tracks: model.subtitleTracks, includeOff: true) { model.selectSubtitle($0) }

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
        tracks: [VLCMediaPlayer.Track],
        includeOff: Bool,
        select: @escaping (VLCMediaPlayer.Track?) -> Void
    ) -> some View {
        Menu {
            if includeOff {
                Button("Off") { select(nil) }
            }
            ForEach(tracks.indices, id: \.self) { i in
                let track = tracks[i]
                Button {
                    select(track)
                } label: {
                    if track.isSelected {
                        Label(MacPlayerModel.name(for: track), systemImage: "checkmark")
                    } else {
                        Text(MacPlayerModel.name(for: track))
                    }
                }
            }
        } label: {
            Image(systemName: systemImage)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(tracks.isEmpty && !includeOff)
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
