import Foundation

/// Static identity Aether sends to Plex on every request.
///
/// Plex uses the `X-Plex-*` headers to identify which app is asking, which
/// device, and which install. The `clientIdentifier` is the stable per-install
/// UUID — Plex uses it to scope sessions and resume points, so it must persist
/// across launches (we round-trip it via `KeychainStore` at app start).
public struct PlexConfiguration: Sendable {
    public let product: String
    public let version: String
    public let clientIdentifier: String
    public let deviceName: String
    public let platform: String
    public let platformVersion: String

    public init(
        product: String,
        version: String,
        clientIdentifier: String,
        deviceName: String,
        platform: String,
        platformVersion: String
    ) {
        self.product = product
        self.version = version
        self.clientIdentifier = clientIdentifier
        self.deviceName = deviceName
        self.platform = platform
        self.platformVersion = platformVersion
    }

    /// The `X-Plex-Client-Profile-Extra` query param sent alongside `directPlay=1`
    /// on the decision endpoint. Tells the server exactly which containers and
    /// codecs Aether can handle natively, so it can approve direct play / direct
    /// stream without re-encoding.
    ///
    /// **iOS / tvOS** — VLCKit handles all major containers (mkv, avi, ts, …) and
    /// codecs (HEVC, DTS, TrueHD, FLAC …). Declaring this lets Plex serve MKV
    /// files directly instead of spending server CPU on a pointless remux.
    ///
    /// **visionOS** — Cinema mode uses the native `AVPlayerViewController`, which
    /// only opens AVFoundation-friendly containers (mp4 / m4v / mov). MKV direct
    /// play via a raw file URL would fail in Cinema. The conservative profile
    /// limits direct play to AVPlayer containers; MKV/HEVC still benefits via
    /// the expanded `add-transcode-target` (server remuxes to HLS/mpegts without
    /// re-encoding video when codecs are compatible).
    ///
    /// **macOS** — libmpv handles everything; full profile, same as iOS/tvOS.
    public var clientProfileExtra: String {
        #if os(visionOS)
        // Conservative: AVPlayer containers only for direct play.
        // HEVC + AC3/EAC3 in HLS is safe for AVPlayer on Apple Vision Pro.
        return [
            "add-direct-play-profile(type=videoProfile" +
                "&container=mp4,m4v,mov" +
                "&videoCodec=h264,hevc,mpeg4" +
                "&audioCodec=aac,mp3,ac3,eac3,alac)",
            "add-transcode-target(type=videoProfile" +
                "&context=streaming&protocol=hls&container=mpegts" +
                "&videoCodec=h264,hevc" +
                "&audioCodec=aac,mp3,ac3,eac3)",
        ].joined(separator: "+")
        #else
        // Full VLCKit / libmpv capability set.
        // MKV + HEVC + DTS can be direct-played as a file (iOS/tvOS → VLC;
        // macOS → libmpv). The broad transcode-target means Plex can also
        // directStream by remuxing MKV to mpegts HLS without re-encoding.
        return [
            "add-direct-play-profile(type=videoProfile" +
                "&container=mkv,mp4,m4v,mov,avi,mpegts,m2ts,webm" +
                "&videoCodec=h264,hevc,mpeg4,mpeg2video,vp9,av1,vc1" +
                "&audioCodec=aac,mp3,ac3,eac3,dts,truehd,vorbis,opus,flac,alac,pcm)",
            "add-transcode-target(type=videoProfile" +
                "&context=streaming&protocol=hls&container=mpegts" +
                "&videoCodec=h264,hevc,mpeg4,mpeg2video,vp9" +
                "&audioCodec=aac,mp3,ac3,eac3,dts,truehd,vorbis,opus,flac,alac)",
        ].joined(separator: "+")
        #endif
    }

    /// Headers sent on every plex.tv and PMS request. JSON is requested
    /// explicitly because Plex defaults to XML if the header isn't set.
    public var commonHeaders: [String: String] {
        [
            "Accept": "application/json",
            "X-Plex-Product": product,
            "X-Plex-Version": version,
            "X-Plex-Client-Identifier": clientIdentifier,
            "X-Plex-Device-Name": deviceName,
            "X-Plex-Platform": platform,
            "X-Plex-Platform-Version": platformVersion
        ]
    }
}
