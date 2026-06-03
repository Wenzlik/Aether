#if os(visionOS)
import SwiftUI
import AVFoundation
import AetherCore

/// The cinema's control plane — a glass attachment slightly closer to the user
/// than the screen, carrying the full transport (since `VideoPlayerComponent`'s
/// native controls don't surface reliably in this immersive setup): scrubber,
/// play/pause, native-style Audio / Subtitles / Quality menus, the screen-size
/// switcher, and Leave.
///
/// The track / quality menus re-resolve playback at the current position (the
/// selection-then-reopen model the rest of the app uses) via the `onSelect…`
/// callbacks the immersive view supplies.
struct CinemaControlsView: View {
    /// The same view model the windowed player uses — Cinema is just a second
    /// renderer of the one `PlaybackSession`.
    let viewModel: PlayerStateViewModel
    @Bindable var cinema: CinemaCoordinator
    /// The item driving the menus' current selections.
    let item: MediaItem?
    let onSelectAudio: (MediaAudioTrack) -> Void
    let onSelectSubtitle: (MediaSubtitleTrack?) -> Void
    let onSelectQuality: (PlaybackQuality) -> Void
    let onLeave: () -> Void

    @State private var position: Double = 0
    @State private var duration: Double = 0
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    private var isPlaying: Bool {
        viewModel.state.status == .playing
    }

    var body: some View {
        VStack(spacing: AetherDesign.Spacing.m) {
            timeline
            controlBar
        }
        .padding(.horizontal, AetherDesign.Spacing.xl)
        .padding(.vertical, AetherDesign.Spacing.l)
        .frame(minWidth: 820)
        .glassBackgroundEffect()
        .tint(AetherDesign.Palette.accent)
        .task { await pollTimeline() }
    }

    // MARK: - Timeline / scrubber

    private var timeline: some View {
        HStack(spacing: AetherDesign.Spacing.m) {
            Text(timeString(scrubbing ? scrubValue : position))
                .font(AetherDesign.Typography.caption)
                .monospacedDigit()
                .foregroundStyle(AetherDesign.Palette.textSecondary)
                .frame(minWidth: 64, alignment: .leading)

            Slider(
                value: Binding(
                    get: { scrubbing ? scrubValue : position },
                    set: { scrubValue = $0 }
                ),
                in: 0...max(duration, 1)
            ) { editing in
                if editing {
                    scrubbing = true
                } else {
                    scrubbing = false
                    let target = scrubValue
                    Task { await viewModel.seek(to: .seconds(target)) }
                }
            }

            Text(timeString(duration))
                .font(AetherDesign.Typography.caption)
                .monospacedDigit()
                .foregroundStyle(AetherDesign.Palette.textSecondary)
                .frame(minWidth: 64, alignment: .trailing)
        }
    }

    private func pollTimeline() async {
        while !Task.isCancelled {
            if let player = viewModel.player {
                let current = player.currentTime().seconds
                if current.isFinite, !scrubbing {
                    position = current
                }
                if let total = player.currentItem?.duration.seconds, total.isFinite, total > 0 {
                    duration = total
                }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    // MARK: - Control bar

    private var controlBar: some View {
        HStack(spacing: AetherDesign.Spacing.l) {
            playPauseButton
            Divider().frame(height: 28)
            screenSizeSwitcher
            if let item {
                Divider().frame(height: 28)
                trackMenus(for: item)
            }
            Divider().frame(height: 28)
            leaveButton
        }
    }

    private var playPauseButton: some View {
        Button {
            Task {
                if isPlaying { await viewModel.pause() } else { await viewModel.play() }
            }
        } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }

    private var screenSizeSwitcher: some View {
        Picker("Screen", selection: $cinema.screenPreset) {
            ForEach(CinemaScreenPreset.ordered, id: \.self) { preset in
                Text(preset.displayName).tag(preset)
            }
        }
        .pickerStyle(.segmented)
        .frame(minWidth: 240)
        .accessibilityLabel("Screen size")
    }

    // MARK: - Track / quality menus

    @ViewBuilder
    private func trackMenus(for item: MediaItem) -> some View {
        if !item.audioTracks.isEmpty {
            Menu {
                ForEach(item.audioTracks) { track in
                    Button {
                        onSelectAudio(track)
                    } label: {
                        selectableLabel(track.displayTitle, isOn: track.id == item.selectedAudioTrackID)
                    }
                }
            } label: {
                menuLabel("Audio", systemImage: "waveform")
            }
        }

        if !item.subtitleTracks.isEmpty {
            Menu {
                Button {
                    onSelectSubtitle(nil)
                } label: {
                    selectableLabel("Off", isOn: item.selectedSubtitleTrackID == nil)
                }
                ForEach(item.subtitleTracks) { track in
                    Button {
                        onSelectSubtitle(track)
                    } label: {
                        selectableLabel(track.displayTitle, isOn: track.id == item.selectedSubtitleTrackID)
                    }
                }
            } label: {
                menuLabel("Subtitles", systemImage: "captions.bubble")
            }
        }

        Menu {
            ForEach(PlaybackQuality.allCases, id: \.self) { quality in
                Button {
                    onSelectQuality(quality)
                } label: {
                    selectableLabel(quality.displayName, isOn: quality == item.selectedQuality)
                }
            }
        } label: {
            menuLabel("Quality", systemImage: "slider.horizontal.3")
        }
    }

    @ViewBuilder
    private func selectableLabel(_ title: String, isOn: Bool) -> some View {
        if isOn {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func menuLabel(_ title: String, systemImage: String) -> some View {
        VStack(spacing: AetherDesign.Spacing.xxs) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
            Text(title)
                .font(AetherDesign.Typography.caption)
        }
        .frame(minWidth: 60)
    }

    // MARK: - Exit

    private var leaveButton: some View {
        Button(role: .destructive) {
            onLeave()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Leave cinema")
    }

    // MARK: - Helpers

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
#endif
