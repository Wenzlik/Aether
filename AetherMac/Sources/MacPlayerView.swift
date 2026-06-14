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
        // Native containers (mp4/mov, HLS from Plex/Jellyfin) → AVPlayer; mkv/DTS
        // → VLCKit. The Mac target links VLCKit 3.x (Vendor/VLCKitMac), which has
        // a working macOS video output — unlike the unified VLCKit 4 (built
        // --disable-macosx) whose GL vout asserted on Apple Silicon (#232).
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
    @State private var failed = false

    init(url: URL) {
        self.url = url
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        ZStack {
            VideoPlayer(player: player)
                .ignoresSafeArea()
            if failed { failureOverlay }
        }
        .navigationTitle(url.deletingPathExtension().lastPathComponent)
        .onAppear { player.play() }
        .onDisappear { player.pause() }
        .task { await watchForFailure() }
    }

    /// AVFoundation can't open some local containers (mkv) / codecs (DTS). Surface
    /// that instead of a black window — those route here only because the VLC
    /// engine is disabled on macOS for now (its GL vout crashes).
    private var failureOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "film.stack").font(.system(size: 48, weight: .light)).foregroundStyle(.secondary)
            Text("Can't play this file").font(.title2.bold())
            Text("\(url.pathExtension.uppercased()) needs the VLC engine, which isn't working on macOS yet. Plex/Jellyfin and MP4/MOV files play fine.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }

    private func watchForFailure() async {
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(300))
            if player.currentItem?.status == .failed { failed = true; return }
        }
    }
}
