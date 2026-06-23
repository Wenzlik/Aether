import SwiftUI
import AVKit
import AetherCore

/// Plays a local Matroska file through the native AVKit player by remuxing it to
/// fragmented MP4 on the fly (#476, Tier 1). The `RemuxedLocalAsset` is held for
/// the player's lifetime (its resource-loader delegate is only weakly retained by
/// AVFoundation), and playback runs through the same `SystemVideoPlayer` chrome as
/// every other AVPlayer title — native transport, PiP, AirPlay.
///
/// This is the AVFoundation alternative to `VLCPlayerView` for local MKVs whose
/// codecs AVFoundation can decode; the routing in `DetailView` picks it when the
/// file is remuxable and falls back to VLCKit otherwise.
struct RemuxPlayerView: View {
    /// Retained here so the resource-loader delegate stays alive while playing.
    let remuxAsset: RemuxedLocalAsset
    let onDismiss: () -> Void

    @State private var player: AVPlayer

    init(remuxAsset: RemuxedLocalAsset, onDismiss: @escaping () -> Void) {
        self.remuxAsset = remuxAsset
        self.onDismiss = onDismiss
        _player = State(initialValue: AVPlayer(playerItem: AVPlayerItem(asset: remuxAsset.asset)))
    }

    var body: some View {
        SystemVideoPlayer(player: player, onDismiss: onDismiss)
            .ignoresSafeArea()
            .task { player.play() }
            .onDisappear { player.pause() }
    }
}
