import SwiftUI
import AetherCore
import VLCKit

/// Minimal VLCKit-backed player for local files AVFoundation can't open (mkv,
/// avi, …) — see `PlaybackEngine` (#173). v1: it plays, with play/pause, a
/// progress bar, and Done. Scrubbing, audio/subtitle selection, resume and
/// Cinema are AVPlayer-only for now and are fast-follows on this engine.
struct VLCPlayerView: UIViewControllerRepresentable {
    let url: URL
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> VLCPlaybackController {
        VLCPlaybackController(url: url, onDismiss: onDismiss)
    }
    func updateUIViewController(_ controller: VLCPlaybackController, context: Context) {}
}

final class VLCPlaybackController: UIViewController {
    private let url: URL
    private let onDismiss: () -> Void
    private let player = VLCMediaPlayer()
    private let videoView = UIView()
    private let playPauseButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)
    private let progress = UIProgressView(progressViewStyle: .default)
    private var ticker: Timer?

    init(url: URL, onDismiss: @escaping () -> Void) {
        self.url = url
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        videoView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(videoView)

        doneButton.setTitle("Done", for: .normal)
        doneButton.tintColor = .white
        doneButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        doneButton.addTarget(self, action: #selector(done), for: .primaryActionTriggered)
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(doneButton)

        playPauseButton.tintColor = .white
        playPauseButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        playPauseButton.addTarget(self, action: #selector(togglePlay), for: .primaryActionTriggered)
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(playPauseButton)

        progress.progressTintColor = .white
        progress.trackTintColor = UIColor.white.withAlphaComponent(0.3)
        progress.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progress)

        NSLayoutConstraint.activate([
            videoView.topAnchor.constraint(equalTo: view.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            videoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            doneButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            doneButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),

            playPauseButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            playPauseButton.bottomAnchor.constraint(equalTo: progress.topAnchor, constant: -16),

            progress.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            progress.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            progress.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20)
        ])

        player.drawable = videoView
        player.media = VLCMedia(url: url)
        player.play()

        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        ticker?.invalidate()
        ticker = nil
        if player.isPlaying { player.stop() }
    }

    private func tick() {
        progress.setProgress(Float(player.position), animated: false)
        let glyph = player.isPlaying ? "pause.fill" : "play.fill"
        playPauseButton.setImage(UIImage(systemName: glyph), for: .normal)
    }

    @objc private func togglePlay() {
        if player.isPlaying { player.pause() } else { player.play() }
    }

    @objc private func done() {
        if player.isPlaying { player.stop() }
        onDismiss()
    }
}
