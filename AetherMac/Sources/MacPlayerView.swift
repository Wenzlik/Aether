import SwiftUI

/// Player window entry point. macOS plays everything through the IINA-style
/// **libmpv** player (`VLCPlayerScreen`) — local mkv/DTS and Plex/Jellyfin HLS
/// alike — for one consistent, high-quality experience (#232).
struct MacPlayerView: View {
    let url: URL
    var session: MacSession?

    var body: some View {
        MpvPlayerScreen(url: url, session: session, item: session?.item(forPlaybackURL: url))
    }
}
