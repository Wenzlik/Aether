import Foundation

/// Tier 1 — the remux-to-fMP4 shim (#476). Sits between AVFoundation (tier 0)
/// and the VLCKit fallback (tier 3): it claims a title only when the container
/// is one AVFoundation can't open directly **but** every track is a codec
/// AVFoundation *can decode*, so rewrapping the elementary streams into
/// fragmented MP4 (no re-encode) yields a natively-playable stream.
///
/// `canPlay` is conservative on purpose. Codecs are unknown until the file is
/// probed (`MatroskaDemuxer`), so before a probe this returns `false` and the
/// title falls through to VLCKit — exactly today's behaviour. Once the caller
/// fills `MediaDescriptor.videoCodec` / `audioCodecs` from a probe, a
/// decodable MKV routes here instead.
public struct RemuxEngine: VideoEngine {
    public let kind: VideoEngineKind = .remux
    public let tier = 1

    /// Containers the shim can rewrap into fMP4. MKV/WebM first (the dominant
    /// "unsupported container" for rips); AVI/TS can follow as the demuxer grows.
    static let remuxableContainers: Set<String> = ["mkv", "webm", "mka"]

    public init() {}

    public func canPlay(_ descriptor: MediaDescriptor) -> Bool {
        guard let container = descriptor.container,
              Self.remuxableContainers.contains(container) else { return false }

        // Don't claim a title whose codecs we haven't learned yet — without a
        // probe we can't guarantee AVFoundation will decode it.
        let hasVideo = descriptor.videoCodec != nil
        let hasAudio = !descriptor.audioCodecs.isEmpty
        guard hasVideo || hasAudio else { return false }

        // Every present A/V track must be something the muxer can actually
        // package — not merely something AVFoundation could decode. A title with
        // (say) H.264 + E-AC-3 is decodable but the muxer can't build an `ec-3`
        // sample entry yet, so remuxing it would drop the only audio and produce
        // silent video — worse than the fallback. Those go to Tier 2/3 instead.
        if let video = descriptor.videoCodec, !video.isRemuxPackageable { return false }
        if descriptor.audioCodecs.contains(where: { !$0.isRemuxPackageable }) { return false }

        return true
    }
}
