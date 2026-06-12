import SwiftUI
import AetherCore
import VLCKit

/// VLCKit-backed player for files AVFoundation can't open (mkv, avi, …) and for
/// SMB streaming (#173/#214). On iOS / visionOS it now has a full control layer
/// — scrubbing, skip ±10s, audio & subtitle track selection, time readouts, and
/// an auto-hiding overlay — so SMB/MKV playback isn't a bare video surface.
/// tvOS keeps the minimal play/pause + progress controls (no `UISlider` there).
struct VLCPlayerView: UIViewControllerRepresentable {
    let url: URL
    /// VLCKit media options applied before play — carries SMB credentials
    /// (`:smb-user=` / `:smb-pwd=` / `:smb-domain=`) and tuned caching (#214).
    var options: [String] = []
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> VLCPlaybackController {
        VLCPlaybackController(url: url, options: options, onDismiss: onDismiss)
    }
    func updateUIViewController(_ controller: VLCPlaybackController, context: Context) {}
}

final class VLCPlaybackController: UIViewController {
    private let url: URL
    private let options: [String]
    private let onDismiss: () -> Void
    private let player = VLCMediaPlayer()
    private let videoView = UIView()
    private var ticker: Timer?

    // Shared controls
    private let playPauseButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)

    private let spinner = UIActivityIndicatorView(style: .large)
    #if os(tvOS)
    private let progress = UIProgressView(progressViewStyle: .default)
    #else
    // Rich controls (iOS / visionOS). The overlay passes taps in its empty
    // areas through to the video (so the tap-to-toggle gesture always fires),
    // while still capturing taps on the actual buttons / slider.
    private let controlsOverlay = PassthroughView()
    private let scrim = UIView()
    private let skipBackButton = UIButton(type: .system)
    private let skipForwardButton = UIButton(type: .system)
    private let tracksButton = UIButton(type: .system)
    private let slider = UISlider()
    private let elapsedLabel = UILabel()
    private let totalLabel = UILabel()
    private var isScrubbing = false
    private var controlsVisible = true
    private var hideWorkItem: DispatchWorkItem?
    private var lastAudioCount = -1
    private var lastTextCount = -1
    private static let skipInterval: Double = 10
    #endif

    init(url: URL, options: [String] = [], onDismiss: @escaping () -> Void) {
        self.url = url
        self.options = options
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        videoView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(videoView)
        NSLayoutConstraint.activate([
            videoView.topAnchor.constraint(equalTo: view.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            videoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        doneButton.setTitle("Done", for: .normal)
        doneButton.tintColor = .white
        doneButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        doneButton.addTarget(self, action: #selector(done), for: .primaryActionTriggered)
        doneButton.translatesAutoresizingMaskIntoConstraints = false

        playPauseButton.tintColor = .white
        playPauseButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        playPauseButton.addTarget(self, action: #selector(togglePlay), for: .primaryActionTriggered)
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false

        setupControls()

        // Loading indicator while the stream connects + buffers — SMB can take a
        // few seconds, and a blank black screen with no spinner reads as frozen.
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        spinner.color = .white
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        spinner.startAnimating()

        player.drawable = videoView
        // Build the libsmb2 request (SMB → smb:// with creds folded into the URL;
        // password stays an option). No-op for non-SMB URLs.
        let request = smb2VLCRequest(url: url, options: options)
        if let media = VLCMedia(url: request.url) {
            for option in request.options { media.addOption(option) }
            player.media = media
        }
        player.play()
        // VLC owns `videoView`'s rendering surface; make sure our controls stay
        // above it (the chrome was unreachable when the video layer sat on top).
        bringControlsToFront()

        // 0.5s ticker drives the progress / time UI and the play-state glyph.
        // Scheduled on the main run loop, so it fires on the main actor.
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Re-assert z-order after VLC has attached its render surface.
        bringControlsToFront()
    }

    private func bringControlsToFront() {
        view.bringSubviewToFront(spinner)
        #if !os(tvOS)
        view.bringSubviewToFront(scrim)
        view.bringSubviewToFront(controlsOverlay)
        #else
        view.bringSubviewToFront(doneButton)
        view.bringSubviewToFront(playPauseButton)
        view.bringSubviewToFront(progress)
        #endif
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        ticker?.invalidate()
        ticker = nil
        if player.isPlaying { player.stop() }
    }

    /// Show the buffering spinner until frames are actually flowing (playing, or
    /// position has advanced), then hide it. Keeps the long SMB connect from
    /// looking like a frozen black screen.
    private func updateSpinner() {
        let active = player.isPlaying || player.position > 0
        if active { spinner.stopAnimating() }
        else if !spinner.isAnimating { spinner.startAnimating() }
    }

    @objc private func togglePlay() {
        if player.isPlaying { player.pause() } else { player.play() }
        #if !os(tvOS)
        scheduleAutoHide()
        #endif
    }

    @objc private func done() {
        if player.isPlaying { player.stop() }
        onDismiss()
    }

    // MARK: - Platform controls

    #if os(tvOS)
    private func setupControls() {
        progress.progressTintColor = .white
        progress.trackTintColor = UIColor.white.withAlphaComponent(0.3)
        progress.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(doneButton)
        view.addSubview(playPauseButton)
        view.addSubview(progress)
        NSLayoutConstraint.activate([
            doneButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            doneButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            playPauseButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            playPauseButton.bottomAnchor.constraint(equalTo: progress.topAnchor, constant: -16),
            progress.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            progress.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            progress.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20)
        ])
    }

    private func tick() {
        updateSpinner()
        progress.setProgress(Float(player.position), animated: false)
        let glyph = player.isPlaying ? "pause.fill" : "play.fill"
        playPauseButton.setImage(UIImage(systemName: glyph), for: .normal)
    }

    #else
    // MARK: Rich controls (iOS / visionOS)

    private func setupControls() {
        // A dim scrim under the controls so white glyphs/text read over bright
        // video; both live in an overlay we fade in/out together.
        scrim.translatesAutoresizingMaskIntoConstraints = false
        scrim.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        scrim.isUserInteractionEnabled = false
        view.addSubview(scrim)

        controlsOverlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controlsOverlay)

        let largeGlyph = UIImage.SymbolConfiguration(pointSize: 44, weight: .regular)
        let medGlyph = UIImage.SymbolConfiguration(pointSize: 30, weight: .regular)

        skipBackButton.tintColor = .white
        skipBackButton.setImage(UIImage(systemName: "gobackward.10", withConfiguration: medGlyph), for: .normal)
        skipBackButton.addTarget(self, action: #selector(skipBack), for: .primaryActionTriggered)
        skipBackButton.translatesAutoresizingMaskIntoConstraints = false

        skipForwardButton.tintColor = .white
        skipForwardButton.setImage(UIImage(systemName: "goforward.10", withConfiguration: medGlyph), for: .normal)
        skipForwardButton.addTarget(self, action: #selector(skipForward), for: .primaryActionTriggered)
        skipForwardButton.translatesAutoresizingMaskIntoConstraints = false

        playPauseButton.setPreferredSymbolConfiguration(largeGlyph, forImageIn: .normal)

        tracksButton.tintColor = .white
        tracksButton.setImage(UIImage(systemName: "captions.bubble"), for: .normal)
        tracksButton.showsMenuAsPrimaryAction = true
        tracksButton.isEnabled = false
        tracksButton.translatesAutoresizingMaskIntoConstraints = false

        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.minimumTrackTintColor = .white
        slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.3)
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.addTarget(self, action: #selector(scrubBegan), for: .touchDown)
        slider.addTarget(self, action: #selector(scrubChanged), for: .valueChanged)
        slider.addTarget(self, action: #selector(scrubEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])

        for label in [elapsedLabel, totalLabel] {
            label.textColor = .white
            label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        elapsedLabel.text = "0:00"
        totalLabel.text = "0:00"
        totalLabel.textAlignment = .right

        for control in [doneButton, tracksButton, skipBackButton, playPauseButton, skipForwardButton, slider, elapsedLabel, totalLabel] {
            controlsOverlay.addSubview(control)
        }

        NSLayoutConstraint.activate([
            scrim.topAnchor.constraint(equalTo: view.topAnchor),
            scrim.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            controlsOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            controlsOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            controlsOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controlsOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            doneButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            doneButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),

            tracksButton.centerYAnchor.constraint(equalTo: doneButton.centerYAnchor),
            tracksButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),

            // Center transport cluster
            playPauseButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            playPauseButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            skipBackButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            skipBackButton.trailingAnchor.constraint(equalTo: playPauseButton.leadingAnchor, constant: -48),
            skipForwardButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            skipForwardButton.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 48),

            // Bottom scrubber row
            slider.leadingAnchor.constraint(equalTo: elapsedLabel.trailingAnchor, constant: 10),
            slider.trailingAnchor.constraint(equalTo: totalLabel.leadingAnchor, constant: -10),
            slider.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            elapsedLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            elapsedLabel.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
            elapsedLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            totalLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            totalLabel.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
            totalLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])

        // Tap the video to toggle the controls.
        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleControls))
        view.addGestureRecognizer(tap)
        scheduleAutoHide()
    }

    private func tick() {
        updateSpinner()
        let glyph = player.isPlaying ? "pause.fill" : "play.fill"
        playPauseButton.setImage(UIImage(systemName: glyph), for: .normal)

        if !isScrubbing {
            slider.value = Float(player.position)
            elapsedLabel.text = player.time.stringValue
            totalLabel.text = totalTime?.stringValue ?? player.media?.length.stringValue ?? "0:00"
        }
        refreshTracksMenuIfNeeded()
    }

    /// Total duration as a `VLCTime` — `media.length` once parsed, else derived
    /// from elapsed + remaining (which VLC knows sooner for some streams).
    private var totalTime: VLCTime? {
        if let length = player.media?.length, length.intValue > 0 { return length }
        let total = player.time.intValue + abs(player.remainingTime?.intValue ?? 0)
        return total > 0 ? VLCTime(int: total) : nil
    }

    private var totalMilliseconds: Double { Double(totalTime?.intValue ?? 0) }

    // MARK: Scrubbing

    @objc private func scrubBegan() {
        isScrubbing = true
        cancelAutoHide()
    }

    @objc private func scrubChanged() {
        // Live elapsed readout while dragging, before committing the seek.
        let ms = Int(Double(slider.value) * totalMilliseconds)
        elapsedLabel.text = VLCTime(int: Int32(ms)).stringValue
    }

    @objc private func scrubEnded() {
        player.position = Double(slider.value)
        isScrubbing = false
        scheduleAutoHide()
    }

    @objc private func skipBack() {
        player.jumpBackward(Self.skipInterval)
        scheduleAutoHide()
    }

    @objc private func skipForward() {
        player.jumpForward(Self.skipInterval)
        scheduleAutoHide()
    }

    // MARK: Track selection

    /// Rebuild the audio/subtitle menu only when the available track counts
    /// change (tracks appear a moment after playback starts as VLC parses).
    private func refreshTracksMenuIfNeeded() {
        let audio = player.audioTracks
        let text = player.textTracks
        guard audio.count != lastAudioCount || text.count != lastTextCount else { return }
        lastAudioCount = audio.count
        lastTextCount = text.count
        tracksButton.isEnabled = !audio.isEmpty || !text.isEmpty
        rebuildTracksMenu()
    }

    private func rebuildTracksMenu() {
        var sections: [UIMenuElement] = []
        let audio = player.audioTracks
        if !audio.isEmpty {
            let items = audio.map { track in
                UIAction(title: Self.title(for: track), state: track.isSelected ? .on : .off) { [weak self] _ in
                    track.isSelectedExclusively = true
                    self?.rebuildTracksMenu()
                }
            }
            sections.append(UIMenu(title: "Audio", options: .displayInline, children: items))
        }
        let text = player.textTracks
        if !text.isEmpty {
            let off = UIAction(title: "Off", state: text.allSatisfy { !$0.isSelected } ? .on : .off) { [weak self] _ in
                self?.player.deselectAllTextTracks()
                self?.rebuildTracksMenu()
            }
            let items = text.map { track in
                UIAction(title: Self.title(for: track), state: track.isSelected ? .on : .off) { [weak self] _ in
                    track.isSelectedExclusively = true
                    self?.rebuildTracksMenu()
                }
            }
            sections.append(UIMenu(title: "Subtitles", options: .displayInline, children: [off] + items))
        }
        tracksButton.menu = UIMenu(title: "", children: sections)
    }

    private static func title(for track: VLCMediaPlayer.Track) -> String {
        let name = track.trackName
        if !name.isEmpty { return name }
        if let language = track.language, !language.isEmpty { return language }
        return "Track"
    }

    // MARK: Controls visibility

    @objc private func toggleControls() {
        setControls(visible: !controlsVisible)
    }

    private func setControls(visible: Bool) {
        controlsVisible = visible
        UIView.animate(withDuration: 0.25) {
            self.controlsOverlay.alpha = visible ? 1 : 0
            self.scrim.alpha = visible ? 1 : 0
        }
        if visible { scheduleAutoHide() } else { cancelAutoHide() }
    }

    /// Auto-hide the controls after a few seconds while playing; keep them up
    /// while paused (nothing to watch, so don't fight the user).
    private func scheduleAutoHide() {
        cancelAutoHide()
        guard player.isPlaying else { return }
        let work = DispatchWorkItem { [weak self] in self?.setControls(visible: false) }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
    }

    private func cancelAutoHide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
    }
    #endif
}

#if !os(tvOS)
/// A control overlay that only captures touches landing on an actual control
/// (button / slider), letting taps in its empty regions fall through to the
/// video's tap-to-toggle gesture. Without this, the full-screen overlay
/// swallowed every tap, so the controls couldn't be toggled (the "tap does
/// nothing / can't reach Done" bug).
final class PassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}
#endif
