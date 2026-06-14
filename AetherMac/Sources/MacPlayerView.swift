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
        // Everything goes through AVPlayer on macOS. The vendored VLCKit was
        // built with `--disable-macosx` (no native macOS video output), so on a
        // Mac it falls back to a generic OpenGL vout that asserts on Apple
        // Silicon's legacy GL 2.1 context (GL_INVALID_OPERATION in CreateFilters)
        // — an unrecoverable C assert. Until VLCKit is vendored with the macOS
        // vout enabled, video can't render through it here. AVPlayer covers
        // Plex/Jellyfin (HLS) + local mp4/mov; a local mkv/DTS file shows a clear
        // message instead of crashing. VLCPlayerScreen is kept for that fix.
        AVKitPlayerScreen(url: url)
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
