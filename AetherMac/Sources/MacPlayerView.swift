import SwiftUI
import AVKit
import AetherCore

/// Player window entry point — **AVPlayer-first, VLCKit fallback** (the Mac
/// strategy): native containers (mp4/mov/m4v, H.264/HEVC) play through
/// AVFoundation for native HW decode, HDR, PiP, AirPlay, and system controls;
/// everything AVFoundation can't open (mkv, DTS, …) falls back to VLCKit. The
/// routing reuses the shared `PlaybackEngine` so it matches the iOS rules.
struct MacPlayerView: View {
    let url: URL

    var body: some View {
        switch PlaybackEngine.engine(for: url) {
        case .system:
            AVKitPlayerScreen(url: url)
        case .vlc:
            VLCPlayerScreen(url: url)
        }
    }
}

/// Native AVFoundation player for AVPlayer-friendly files — `VideoPlayer` gives
/// the full system player chrome (scrub, volume, PiP, AirPlay, full-screen) for
/// free, which is the Mac-native quality win over routing everything to VLC.
struct AVKitPlayerScreen: View {
    let url: URL
    @State private var player: AVPlayer

    init(url: URL) {
        self.url = url
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VideoPlayer(player: player)
            .ignoresSafeArea()
            .navigationTitle(url.deletingPathExtension().lastPathComponent)
            .onAppear { player.play() }
            .onDisappear { player.pause() }
    }
}
