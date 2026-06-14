import SwiftUI
import VLCKit

/// Minimal native-macOS VLC surface — plays a local file (MKV/DTS/multi-track)
/// in an `NSView` the system window frames. The rich player chrome (scrubbing,
/// audio/subtitle track menus, keyboard shortcuts) is the next step (#232); this
/// proves VLCKit's `macos` slice plays through a SwiftUI `NSViewControllerRepresentable`.
struct VLCMacPlayerView: NSViewControllerRepresentable {
    let url: URL

    func makeNSViewController(context: Context) -> VLCMacPlaybackController {
        VLCMacPlaybackController(url: url)
    }

    func updateNSViewController(_ controller: VLCMacPlaybackController, context: Context) {
        controller.play(url: url)
    }
}

final class VLCMacPlaybackController: NSViewController {
    private let player = VLCMediaPlayer()
    private var currentURL: URL?

    init(url: URL) {
        self.currentURL = url
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let surface = NSView()
        surface.wantsLayer = true
        surface.layer?.backgroundColor = NSColor.black.cgColor
        view = surface
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        player.drawable = view
        if let currentURL { start(currentURL) }
    }

    /// Swap to a new file (the window is reused across Open… picks).
    func play(url: URL) {
        guard url != currentURL else { return }
        currentURL = url
        start(url)
    }

    private func start(_ url: URL) {
        if let media = VLCMedia(url: url) {
            player.media = media
        }
        player.play()
    }
}
