import SwiftUI
import AetherCore
import VLCKit
import MediaPlayer
import os

/// VLCKit-backed player for files AVFoundation can't open (mkv, avi, …) and for
/// SMB streaming (#173/#214). On iOS / visionOS it has a full control layer —
/// scrubbing, skip ±10s, double-tap seek, playback speed, fill-mode toggle,
/// audio & subtitle track selection, time readouts, and an auto-hiding overlay.
/// Lock screen / AirPods controls (MPRemoteCommandCenter) work on all platforms.
/// tvOS has a leaner overlay with remote-based seeking and a swipe-down info
/// panel for audio/subtitle/speed selection.
struct VLCPlayerView: UIViewControllerRepresentable {
    let url: URL
    /// VLCKit media options applied before play — carries SMB credentials
    /// (`:smb-user=` / `:smb-pwd=` / `:smb-domain=`) and tuned caching (#214).
    var options: [String] = []
    /// Shown on the lock screen / Control Center while playing.
    var mediaTitle: String = ""
    /// Preferred audio / subtitle **language** (the app's playback defaults).
    /// SMB files carry no track list before playback, so instead of a Detail
    /// picker we auto-select the matching track the moment VLC parses them — the
    /// "choose before you watch" outcome, driven by Settings. `"off"` subtitle
    /// preference disables subtitles. `nil` = leave VLC's defaults.
    var preferredAudioLanguage: String? = nil
    var preferredSubtitleLanguage: String? = nil
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> VLCPlaybackController {
        VLCPlaybackController(
            url: url,
            options: options,
            mediaTitle: mediaTitle,
            preferredAudioLanguage: preferredAudioLanguage,
            preferredSubtitleLanguage: preferredSubtitleLanguage,
            onDismiss: onDismiss
        )
    }
    func updateUIViewController(_ controller: VLCPlaybackController, context: Context) {}
}

final class VLCPlaybackController: UIViewController {
    private let url: URL
    private let options: [String]
    private let mediaTitle: String
    private let preferredAudioLanguage: String?
    private let preferredSubtitleLanguage: String?
    private var appliedPreferredTracks = false
    private let onDismiss: () -> Void
    private let player = VLCMediaPlayer()
    private let videoView = UIView()
    private var ticker: Timer?
    private var backgroundObservers: [NSObjectProtocol] = []

    // MARK: - Startup timing instrumentation (#347)
    /// Read in Console.app, subsystem `cz.zmrhal.aether`, category `PlaybackTiming`.
    /// Isolates where SMB/MKV time-to-first-frame goes — SMB connect vs VLC parse
    /// vs decode init — so optimisation isn't guesswork.
    private static let perfLog = Logger(subsystem: "cz.zmrhal.aether", category: "PlaybackTiming")
    /// Wall-clock when `play()` was issued; all phase timings are deltas from it.
    private var playRequestedAt: Date?
    /// VLC states already logged, so each transition is recorded once.
    private var loggedStates = Set<Int>()
    /// Guards the one-shot "first frame" log (first `timeChanged`).
    private var firstFrameLogged = false

    /// Milliseconds since `play()` was issued, for log lines.
    private func elapsedMS() -> Int {
        guard let playRequestedAt else { return 0 }
        return Int(Date().timeIntervalSince(playRequestedAt) * 1000)
    }

    /// The configured `:network-caching=` value (ms), parsed from the media
    /// options — logged so a run is self-documenting when A/B-testing cache.
    private func cachingOptionMS() -> String {
        for opt in options where opt.hasPrefix(":network-caching=") {
            return String(opt.dropFirst(":network-caching=".count))
        }
        return "default"
    }

    // MARK: - Shared controls / state

    private let playPauseButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .large)
    private static let skipInterval: Double = 10
    /// Current playback rate — shared across platforms so `updateNowPlayingInfo`
    /// can reflect speed changes from both the iOS speed menu and the tvOS panel.
    private var currentRate: Float = 1.0

    // MARK: - Total duration (shared — used by lock screen info on all platforms)

    /// Total duration as a `VLCTime` — `media.length` once parsed, else derived
    /// from elapsed + remaining (VLC often knows remaining before the full parse).
    private var totalTime: VLCTime? {
        if let length = player.media?.length, length.intValue > 0 { return length }
        let total = player.time.intValue + abs(player.remainingTime?.intValue ?? 0)
        return total > 0 ? VLCTime(int: total) : nil
    }
    private var totalMilliseconds: Double { Double(totalTime?.intValue ?? 0) }

    #if os(tvOS)
    private let progress = UIProgressView(progressViewStyle: .default)
    private var infoPanel: VLCInfoPanelController?
    #else
    // Rich controls (iOS / visionOS). The overlay passes taps in its empty
    // areas through to the video (so the tap-to-toggle gesture always fires),
    // while still capturing taps on the actual buttons / slider.
    private let controlsOverlay = PassthroughView()
    private let scrim = UIView()
    private let skipBackButton = UIButton(type: .system)
    private let skipForwardButton = UIButton(type: .system)
    /// Combined tracks + speed menu button.
    private let tracksButton = UIButton(type: .system)
    /// Fill / fit toggle — forces the display's aspect ratio to crop black bars.
    private let fillButton = UIButton(type: .system)
    private let slider = UISlider()
    private let elapsedLabel = UILabel()
    private let totalLabel = UILabel()
    private var isScrubbing = false
    private var controlsVisible = true
    private var hideWorkItem: DispatchWorkItem?
    private var lastAudioCount = -1
    private var lastTextCount = -1
    private var videoFillEnabled = false
    #endif

    init(
        url: URL,
        options: [String] = [],
        mediaTitle: String = "",
        preferredAudioLanguage: String? = nil,
        preferredSubtitleLanguage: String? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.url = url
        self.options = options
        self.mediaTitle = mediaTitle
        self.preferredAudioLanguage = preferredAudioLanguage
        self.preferredSubtitleLanguage = preferredSubtitleLanguage
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
        setupNowPlaying()

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
        player.delegate = self
        // Build the libsmb2 request (SMB → smb:// with creds folded into the URL;
        // password stays an option). No-op for non-SMB URLs.
        let request = smb2VLCRequest(url: url, options: options)
        if let media = VLCMedia(url: request.url) {
            for option in request.options { media.addOption(option) }
            player.media = media
        }
        let scheme = url.scheme ?? "?"
        Self.perfLog.log("▶︎ play requested — scheme=\(scheme, privacy: .public) caching=\(self.cachingOptionMS(), privacy: .public)ms")
        playRequestedAt = Date()
        player.play()
        // VLC owns `videoView`'s rendering surface; make sure our controls stay
        // above it (the chrome was unreachable when the video layer sat on top).
        bringControlsToFront()

        // 0.5s ticker drives the progress / time UI and the play-state glyph.
        // Scheduled on the main run loop, so it fires on the main actor.
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        backgroundObservers = [
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                self?.ticker?.invalidate()
                self?.ticker = nil
            },
            NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                guard self?.ticker == nil else { return }
                self?.ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
                MainActor.assumeIsolated { self?.tick() }
            }
        ]
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
        backgroundObservers.forEach { NotificationCenter.default.removeObserver($0) }
        backgroundObservers = []
        ticker?.invalidate()
        ticker = nil
        if player.isPlaying { player.stop() }
        teardownNowPlaying()
    }

    /// Show the buffering spinner until frames are actually flowing (playing, or
    /// position has advanced), then hide it. Keeps the long SMB connect from
    /// looking like a frozen black screen.
    private func updateSpinner() {
        let active = player.isPlaying || player.position > 0
        if active { spinner.stopAnimating() }
        else if !spinner.isAnimating { spinner.startAnimating() }
    }

    /// Once VLC has parsed the tracks, select the audio/subtitle matching the
    /// app's default languages — the "choose before you watch" behaviour for SMB
    /// (which has no pre-play track list). Runs once.
    @discardableResult
    private func applyPreferredTracksIfNeeded() -> Bool {
        guard !appliedPreferredTracks else { return false }
        let audio = player.audioTracks
        let text = player.textTracks
        guard !audio.isEmpty || !text.isEmpty else { return false }   // wait for parse
        appliedPreferredTracks = true

        if let pref = preferredAudioLanguage, !pref.isEmpty {
            let want = AudioLanguage.canonical(pref)
            if let match = audio.first(where: { AudioLanguage.canonical($0.language) == want }) {
                match.isSelectedExclusively = true
            }
        }
        if let pref = preferredSubtitleLanguage {
            if pref == "off" {
                player.deselectAllTextTracks()
            } else if !pref.isEmpty {
                let want = AudioLanguage.canonical(pref)
                if let match = text.first(where: { AudioLanguage.canonical($0.language) == want }) {
                    match.isSelectedExclusively = true
                }
            }
        }
        return true
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

    // MARK: - Lock screen / Now Playing (all platforms)

    private func setupNowPlaying() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)

        let cc = MPRemoteCommandCenter.shared()

        cc.togglePlayPauseCommand.isEnabled = true
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlay(); return .success
        }
        cc.playCommand.isEnabled = true
        cc.playCommand.addTarget { [weak self] _ in
            self?.player.play(); return .success
        }
        cc.pauseCommand.isEnabled = true
        cc.pauseCommand.addTarget { [weak self] _ in
            self?.player.pause(); return .success
        }
        cc.skipForwardCommand.isEnabled = true
        cc.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        cc.skipForwardCommand.addTarget { [weak self] _ in
            self?.player.jumpForward(Self.skipInterval); return .success
        }
        cc.skipBackwardCommand.isEnabled = true
        cc.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        cc.skipBackwardCommand.addTarget { [weak self] _ in
            self?.player.jumpBackward(Self.skipInterval); return .success
        }
        cc.changePlaybackPositionCommand.isEnabled = true
        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let e = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let totalSec = self.totalMilliseconds / 1000.0
            guard totalSec > 0 else { return .commandFailed }
            self.player.position = e.positionTime / totalSec
            return .success
        }
    }

    private func teardownNowPlaying() {
        let cc = MPRemoteCommandCenter.shared()
        cc.togglePlayPauseCommand.removeTarget(nil)
        cc.playCommand.removeTarget(nil)
        cc.pauseCommand.removeTarget(nil)
        cc.skipForwardCommand.removeTarget(nil)
        cc.skipBackwardCommand.removeTarget(nil)
        cc.changePlaybackPositionCommand.removeTarget(nil)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func updateNowPlayingInfo() {
        let totalSec = totalMilliseconds / 1000.0
        let elapsedSec = Double(player.time.intValue) / 1000.0
        let playbackRate = player.isPlaying ? Double(currentRate) : 0.0
        var info: [String: Any] = [
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPMediaItemPropertyTitle: mediaTitle,
            MPNowPlayingInfoPropertyPlaybackRate: playbackRate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if totalSec > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = totalSec
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedSec
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
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

        // Swipe down on the Siri Remote touch surface → info/settings panel.
        let swipeDown = UISwipeGestureRecognizer(target: self, action: #selector(showInfoPanel))
        swipeDown.direction = .down
        view.addGestureRecognizer(swipeDown)
    }

    private func tick() {
        updateSpinner()
        applyPreferredTracksIfNeeded()
        progress.setProgress(Float(player.position), animated: false)
        let glyph = player.isPlaying ? "pause.fill" : "play.fill"
        playPauseButton.setImage(UIImage(systemName: glyph), for: .normal)
        updateNowPlayingInfo()
    }

    /// Siri Remote seeking: left/right swipe/press = ±10s.
    /// Seeking is suppressed while the info panel is open — the d-pad navigates
    /// the panel's focusable rows instead.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard infoPanel == nil else { super.pressesBegan(presses, with: event); return }
        var handled = false
        for press in presses where !handled {
            switch press.type {
            case .leftArrow:
                player.jumpBackward(Self.skipInterval)
                handled = true
            case .rightArrow:
                player.jumpForward(Self.skipInterval)
                handled = true
            default: break
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    // MARK: Info panel (tvOS)

    @objc private func showInfoPanel() {
        guard infoPanel == nil else { return }
        let panel = VLCInfoPanelController(
            player: player,
            title: mediaTitle,
            currentRate: currentRate,
            onRateChange: { [weak self] rate in self?.currentRate = rate },
            onDismiss: { [weak self] in
                self?.infoPanel = nil
                self?.setNeedsFocusUpdate()
                self?.updateFocusIfNeeded()
            }
        )
        infoPanel = panel
        addChild(panel)
        panel.view.alpha = 0
        panel.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel.view)
        NSLayoutConstraint.activate([
            panel.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            panel.view.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.48),
        ])
        panel.didMove(toParent: self)
        view.layoutIfNeeded()

        panel.view.transform = CGAffineTransform(translationX: 0, y: panel.view.bounds.height)
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.9,
                       initialSpringVelocity: 0, options: .curveEaseOut) {
            panel.view.alpha = 1
            panel.view.transform = .identity
        }
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let panel = infoPanel { return [panel] }
        return super.preferredFocusEnvironments
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

        // Combined tracks + speed button. Icon changed to ⋯ since it now holds
        // more than captions (the captions.bubble icon would be misleading).
        tracksButton.tintColor = .white
        tracksButton.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
        tracksButton.showsMenuAsPrimaryAction = true
        tracksButton.translatesAutoresizingMaskIntoConstraints = false
        rebuildTracksMenu()   // seed the menu so the button works immediately

        fillButton.tintColor = .white
        fillButton.setImage(UIImage(systemName: "arrow.up.left.and.arrow.down.right"), for: .normal)
        fillButton.addTarget(self, action: #selector(toggleFillMode), for: .primaryActionTriggered)
        fillButton.translatesAutoresizingMaskIntoConstraints = false

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

        for control in [doneButton, fillButton, tracksButton, skipBackButton,
                        playPauseButton, skipForwardButton, slider, elapsedLabel, totalLabel] {
            controlsOverlay.addSubview(control)
        }

        // Double-tap left/right half to seek ±10s; single-tap toggles controls.
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)

        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleControls))
        // Single-tap only fires after the double-tap window expires, preventing
        // the first tap of a double-tap from hiding/showing the controls.
        tap.require(toFail: doubleTap)
        view.addGestureRecognizer(tap)

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

            // Top-right: [fillButton] [tracksButton]
            tracksButton.centerYAnchor.constraint(equalTo: doneButton.centerYAnchor),
            tracksButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            fillButton.centerYAnchor.constraint(equalTo: doneButton.centerYAnchor),
            fillButton.trailingAnchor.constraint(equalTo: tracksButton.leadingAnchor, constant: -20),

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
        // Auto-select the preferred audio/subtitle once tracks parse; refresh the
        // menu so the new selection's checkmarks show.
        if applyPreferredTracksIfNeeded() { rebuildTracksMenu() }
        updateNowPlayingInfo()
    }

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

    // MARK: Double-tap seek

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: view)
        if location.x < view.bounds.midX {
            player.jumpBackward(Self.skipInterval)
        } else {
            player.jumpForward(Self.skipInterval)
        }
        // Ensure controls surface briefly so the updated position is visible.
        setControls(visible: true)
        scheduleAutoHide()
    }

    // MARK: Track + Speed selection

    /// Rebuild the audio/subtitle/speed menu only when track counts change
    /// (tracks appear a moment after playback starts as VLC parses).
    private func refreshTracksMenuIfNeeded() {
        let audio = player.audioTracks
        let text = player.textTracks
        guard audio.count != lastAudioCount || text.count != lastTextCount else { return }
        lastAudioCount = audio.count
        lastTextCount = text.count
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

        let speeds: [(Float, String)] = [
            (0.5, "0.5×"), (0.75, "0.75×"), (1.0, "1×"),
            (1.25, "1.25×"), (1.5, "1.5×"), (2.0, "2×")
        ]
        let speedItems = speeds.map { speed, label -> UIAction in
            UIAction(title: label, state: abs(currentRate - speed) < 0.01 ? .on : .off) { [weak self] _ in
                self?.currentRate = speed
                self?.player.rate = speed
                self?.rebuildTracksMenu()
            }
        }
        sections.append(UIMenu(
            title: String(localized: "Speed"),
            options: .displayInline,
            children: speedItems
        ))

        tracksButton.menu = UIMenu(title: "", children: sections)
    }

    private static func title(for track: VLCMediaPlayer.Track) -> String {
        let name = track.trackName
        if !name.isEmpty { return name }
        if let language = track.language, !language.isEmpty { return language }
        return "Track"
    }

    // MARK: Fill mode

    /// Toggles between fit (letterboxed, default) and fill (crops to display
    /// aspect ratio, no black bars). Fill forces `videoAspectRatio` to the
    /// screen's ratio — VLC zooms and crops the video to match.
    @objc private func toggleFillMode() {
        videoFillEnabled.toggle()
        if videoFillEnabled {
            let w = Int(view.bounds.width)
            let h = Int(view.bounds.height)
            guard w > 0, h > 0 else { videoFillEnabled = false; return }
            let g = Self.gcd(w, h)
            player.videoAspectRatio = "\(w / g):\(h / g)"
        } else {
            player.videoAspectRatio = nil
        }
        let icon = videoFillEnabled
            ? "arrow.down.right.and.arrow.up.left"
            : "arrow.up.left.and.arrow.down.right"
        fillButton.setImage(UIImage(systemName: icon), for: .normal)
        scheduleAutoHide()
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        b == 0 ? a : gcd(b, a % b)
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

// MARK: - Startup timing (#347)

// `@preconcurrency`: VLCKit dispatches delegate callbacks on the main thread, so
// the MainActor-isolated controller can safely conform (Swift 6 can't see that
// guarantee through the ObjC protocol).
extension VLCPlaybackController: @preconcurrency VLCMediaPlayerDelegate {
    /// Logs each VLC state transition once, with ms since `play()`. The sequence
    /// for SMB is typically opening → buffering → playing; a long gap before
    /// `buffering` points at SMB connect/parse, a long gap before the first
    /// frame at decode/parse.
    func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        guard loggedStates.insert(newState.rawValue).inserted else { return }
        let name = VLCMediaPlayerStateToString(newState)
        Self.perfLog.log("• state=\(name, privacy: .public) @ \(self.elapsedMS(), privacy: .public)ms")
    }

    /// First time-change ≈ first decoded/presented frame — the number that
    /// matters for "time to first frame".
    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        guard !firstFrameLogged else { return }
        firstFrameLogged = true
        Self.perfLog.log("✓ first frame (time changed) @ \(self.elapsedMS(), privacy: .public)ms  hasVideoOut=\(self.player.hasVideoOut, privacy: .public)")
    }
}

// MARK: - tvOS info/settings panel

#if os(tvOS)
/// Slides up from the bottom of the player on a Siri Remote swipe-down. Shows
/// audio track, subtitle, and speed selection in a three-column layout.
/// Menu button dismisses; d-pad navigates between items naturally via tvOS focus.
final class VLCInfoPanelController: UIViewController {
    private let player: VLCMediaPlayer
    private let mediaTitle: String
    private var currentRate: Float
    private let onRateChange: (Float) -> Void
    private let onDismiss: () -> Void

    private let columnsStack = UIStackView()

    init(
        player: VLCMediaPlayer,
        title: String,
        currentRate: Float,
        onRateChange: @escaping (Float) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.player = player
        self.mediaTitle = title
        self.currentRate = currentRate
        self.onRateChange = onRateChange
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        blur.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(blur)

        // Thin separator line at the top of the panel
        let separator = UIView()
        separator.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        separator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(separator)

        let titleLabel = UILabel()
        titleLabel.text = mediaTitle
        titleLabel.font = UIFont.systemFont(ofSize: 28, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        columnsStack.axis = .horizontal
        columnsStack.distribution = .fillEqually
        columnsStack.alignment = .top
        columnsStack.spacing = 60
        columnsStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(columnsStack)

        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: view.topAnchor),
            blur.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            separator.topAnchor.constraint(equalTo: view.topAnchor),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 44),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 90),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -90),

            columnsStack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 28),
            columnsStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 90),
            columnsStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -90),
        ])

        buildColumns()
    }

    private func buildColumns() {
        columnsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let audioTracks = player.audioTracks
        if !audioTracks.isEmpty {
            let items: [(String, Bool, () -> Void)] = audioTracks.map { track in
                (Self.trackLabel(track), track.isSelected, { [weak self] in
                    track.isSelectedExclusively = true
                    self?.buildColumns()
                })
            }
            columnsStack.addArrangedSubview(buildColumn(
                header: String(localized: "Audio"),
                items: items
            ))
        }

        let subtitleTracks = player.textTracks
        if !subtitleTracks.isEmpty {
            let offSelected = subtitleTracks.allSatisfy { !$0.isSelected }
            var items: [(String, Bool, () -> Void)] = [
                (String(localized: "Off"), offSelected, { [weak self] in
                    self?.player.deselectAllTextTracks()
                    self?.buildColumns()
                })
            ]
            items += subtitleTracks.map { track in
                (Self.trackLabel(track), track.isSelected, { [weak self] in
                    track.isSelectedExclusively = true
                    self?.buildColumns()
                })
            }
            columnsStack.addArrangedSubview(buildColumn(
                header: String(localized: "Subtitles"),
                items: items
            ))
        }

        let speeds: [(Float, String)] = [
            (0.5, "0.5×"), (0.75, "0.75×"), (1.0, "1×"),
            (1.25, "1.25×"), (1.5, "1.5×"), (2.0, "2×")
        ]
        let speedItems: [(String, Bool, () -> Void)] = speeds.map { speed, label in
            (label, abs(currentRate - speed) < 0.01, { [weak self] in
                guard let self else { return }
                self.currentRate = speed
                self.player.rate = speed
                self.onRateChange(speed)
                self.buildColumns()
            })
        }
        columnsStack.addArrangedSubview(buildColumn(
            header: String(localized: "Speed"),
            items: speedItems
        ))
    }

    private func buildColumn(header: String, items: [(String, Bool, () -> Void)]) -> UIView {
        let col = UIStackView()
        col.axis = .vertical
        col.spacing = 2
        col.alignment = .leading

        let headerLabel = UILabel()
        headerLabel.text = header.uppercased()
        headerLabel.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        headerLabel.textColor = UIColor.white.withAlphaComponent(0.45)
        col.addArrangedSubview(headerLabel)
        col.setCustomSpacing(14, after: headerLabel)

        for (title, selected, action) in items {
            col.addArrangedSubview(makeItemButton(title: title, selected: selected, action: action))
        }
        return col
    }

    private func makeItemButton(title: String, selected: Bool, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.title = title
        config.image = UIImage(systemName: selected ? "checkmark.circle.fill" : "circle")
        config.imagePlacement = .leading
        config.imagePadding = 10
        config.baseForegroundColor = selected ? .white : UIColor.white.withAlphaComponent(0.55)
        let btn = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        btn.contentHorizontalAlignment = .leading
        return btn
    }

    private static func trackLabel(_ track: VLCMediaPlayer.Track) -> String {
        let name = track.trackName
        if !name.isEmpty { return name }
        if let lang = track.language, !lang.isEmpty { return lang }
        return "Track"
    }

    /// Menu button dismisses the panel; all other presses fall through to the
    /// focus system so d-pad navigation between column buttons works normally.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .menu {
            animatedDismiss()
            return
        }
        super.pressesBegan(presses, with: event)
    }

    func animatedDismiss() {
        UIView.animate(withDuration: 0.25, animations: {
            self.view.transform = CGAffineTransform(translationX: 0, y: self.view.bounds.height)
            self.view.alpha = 0
        }) { _ in
            self.willMove(toParent: nil)
            self.view.removeFromSuperview()
            self.removeFromParent()
            self.onDismiss()
        }
    }
}
#endif

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
