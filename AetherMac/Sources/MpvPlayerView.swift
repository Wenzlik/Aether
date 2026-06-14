import SwiftUI
import AetherCore

/// IINA-style **libmpv** player — the macOS engine (#232). Full-bleed video with
/// an auto-hiding floating control bar (scrub, ±10s, play/pause, time, volume,
/// audio/subtitle menus, full-screen) and keyboard shortcuts (space, ←/→). The
/// video surface is `MpvVideoView` (OpenGL render context on this player).
struct MpvPlayerScreen: View {
    let url: URL
    var session: MacSession?
    var item: MediaItem?
    /// Dismiss the inline player (back to the library).
    var onClose: (() -> Void)?
    @State private var model = MacPlayerModel()
    @State private var controlsVisible = true
    @State private var hideWorkItem: DispatchWorkItem?

    var body: some View {
        @Bindable var model = model
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            MpvVideoView(client: model.mpv).ignoresSafeArea()

            if controlsVisible {
                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                    controlBar(model)
                }
                .transition(.opacity)
            }
        }
        .onAppear { model.load(url, session: session, item: item); scheduleHide() }
        .onDisappear { model.stop() }
        .onChange(of: url) { _, newURL in model.load(newURL, session: session, item: item) }
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
    }

    // MARK: Chrome

    /// Top bar with a Close (←) button + the title, over a subtle gradient.
    private var topBar: some View {
        HStack(spacing: 12) {
            Button { onClose?() } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 16, weight: .semibold))
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Close player")

            Text(model.title)
                .font(.headline)
                .foregroundStyle(.white)
                .shadow(radius: 4)
                .lineLimit(1)
            Spacer()
        }
        // Extra leading inset so the Close button clears the window's traffic
        // lights, which float over the full-bleed player.
        .padding(.leading, 80)
        .padding(.trailing, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom))
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
            Button("") { onClose?() }.keyboardShortcut(.escape, modifiers: [])
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
