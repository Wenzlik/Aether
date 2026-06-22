import Foundation

/// Which playback engine should handle a given title.
///
/// This is the capability-tiered seam that replaces the old two-case
/// `PlaybackEngine` enum (#476). The product is moving off VLCKit (an App Store
/// license risk) toward an AVFoundation-first, capability-tiered stack: each
/// title routes to the **cheapest tier that can play it**. Modelling the choice
/// as a protocol + ordered engines — rather than a hard-coded enum switch —
/// means adding a tier (remux shim, libmpv-LGPL fallback) or removing one
/// (deleting VLCKit in P3) is a *conformer + one resolver entry*, not a rewrite
/// of every routing call site.
///
/// Server sources (Plex/Jellyfin) hand us HLS (`.m3u8`) or remuxed MP4 — those
/// resolve to `.avFoundation`. The `.vlc` path only exists for local/SMB files
/// in a container AVFoundation can't demux, and is **temporary**: it goes away
/// once the AVFoundation-first cut ships and the remux / libmpv tiers land.

// MARK: - Kind

/// The concrete engines Aether can route to today. Lower-tier engines are
/// preferred; see `VideoEngine.tier`.
public enum VideoEngineKind: Sendable, Equatable {
    /// `AVPlayer` / `AVPlayerViewController` — native controls, PiP, AirPlay,
    /// HDR, hardware decode. The default and the only App-Store-clean engine.
    case avFoundation
    /// Remux-to-fMP4 shim — rewrites a non-AVFoundation container (mkv, …)
    /// wrapping Apple-decodable codecs into fragmented MP4 on the fly, no
    /// re-encode, then plays it via AVFoundation (#476, Tier 1).
    case remux
    /// VLCKit — handles containers/codecs AVFoundation can't (mkv, avi, …).
    /// **Temporary**: removed once the AVFoundation-first cut ships (#476 P3).
    case vlc
}

// MARK: - Descriptor

/// What Aether knows about a title *before* playback — enough to choose an
/// engine without a live stream. Built either from a resolved playback URL or
/// from a raw container name (Plex's `Media.container`, known at download time
/// before any URL exists).
public struct MediaDescriptor: Sendable, Equatable {
    /// URL scheme, lowercased (`"smb"`, `"https"`, `"file"`, …). `nil` when
    /// routing on a bare container name.
    public var scheme: String?
    /// Container / file extension, lowercased (`"mkv"`, `"mp4"`, …). `nil` for
    /// an extension-less URL (a transcode/HLS URL) or an unknown container —
    /// both of which default to AVFoundation.
    public var container: String?
    /// Video codec, when known (from a Matroska probe or `MediaInfo`). `nil`
    /// before a probe — Tier 1 can't promise playback without it.
    public var videoCodec: VideoCodec?
    /// Audio codecs present, when known. Empty before a probe.
    public var audioCodecs: [AudioCodec]

    public init(
        scheme: String? = nil,
        container: String? = nil,
        videoCodec: VideoCodec? = nil,
        audioCodecs: [AudioCodec] = []
    ) {
        self.scheme = scheme?.lowercased()
        let c = container?.lowercased()
        self.container = (c?.isEmpty == true) ? nil : c
        self.videoCodec = videoCodec
        self.audioCodecs = audioCodecs
    }

    /// Describe a resolved playback URL: scheme + path extension. Codecs are
    /// unknown from a URL alone (fill them from a probe / `MediaInfo`).
    public init(url: URL) {
        let ext = url.pathExtension.lowercased()
        self.init(scheme: url.scheme, container: ext.isEmpty ? nil : ext)
    }
}

// MARK: - Engine protocol

/// A playback engine's *capability*: which titles it can play and how cheap it
/// is to use. Engines are ordered by `tier` and the resolver picks the lowest
/// tier that returns `true` from `canPlay`. Pure + `Sendable` so routing is
/// deterministic and unit-tested.
public protocol VideoEngine: Sendable {
    /// The concrete engine this capability resolves to.
    var kind: VideoEngineKind { get }
    /// Preference order — **lower is cheaper / preferred**. The resolver tries
    /// engines in ascending tier and stops at the first that can play. Tiers
    /// mirror #476: 0 = AVFoundation, (1 = remux shim, 2 = server transcode —
    /// future), 3 = VLCKit/libmpv fallback.
    var tier: Int { get }
    /// Whether this engine can play the described title.
    func canPlay(_ descriptor: MediaDescriptor) -> Bool
}

// MARK: - Concrete engines

/// Tier 0 — AVFoundation. Plays the containers `AVPlayer` opens directly (incl.
/// HLS). Cannot open `smb://` at all (#214), so SMB falls through even for an
/// `.mp4` (the SMB HTTP range-proxy re-routes those to a `file`/`http` URL with
/// the right extension before this is asked again).
public struct AVFoundationEngine: VideoEngine {
    public let kind: VideoEngineKind = .avFoundation
    public let tier = 0

    /// Lowercased containers AVFoundation opens directly (incl. HLS).
    static let playableContainers: Set<String> = [
        "mp4", "m4v", "mov", "m4a", "3gp", "3g2", "mp3", "aac", "m3u8"
    ]

    public init() {}

    public func canPlay(_ descriptor: MediaDescriptor) -> Bool {
        // AVPlayer can't open SMB; route it elsewhere.
        if descriptor.scheme == "smb" { return false }
        // No/unknown container (e.g. a transcode/HLS URL without an extension)
        // → don't restrict; AVFoundation is the default.
        guard let container = descriptor.container else { return true }
        return Self.playableContainers.contains(container)
    }
}

/// Tier 3 — VLCKit. The universal fallback for everything AVFoundation can't
/// open. **Temporary** (#476): once the remux/libmpv tiers land this conformer
/// is replaced. Being the highest tier, it's only chosen when no cheaper engine
/// can play the title.
public struct VLCEngine: VideoEngine {
    public let kind: VideoEngineKind = .vlc
    public let tier = 3

    public init() {}

    /// VLCKit is the last-resort engine — it plays anything we'd otherwise have
    /// no engine for.
    public func canPlay(_ descriptor: MediaDescriptor) -> Bool { true }
}

// MARK: - Resolver

/// Picks the engine for a title: the lowest-tier installed engine whose
/// `canPlay` is `true`. An immutable value (not a service) — construct one or
/// use `.standard`; inject a custom engine list in tests.
public struct VideoEngineResolver: Sendable {
    private let engines: [any VideoEngine]

    /// `engines` are sorted by tier on init, so caller order doesn't matter.
    public init(engines: [any VideoEngine] = VideoEngineResolver.installedEngines) {
        self.engines = engines.sorted { $0.tier < $1.tier }
    }

    /// The engines Aether ships on the iOS family today: AVFoundation first,
    /// the remux shim for decodable codecs in unsupported containers, VLCKit as
    /// the temporary last-resort fallback.
    public static let installedEngines: [any VideoEngine] = [
        AVFoundationEngine(),
        RemuxEngine(),
        VLCEngine()
    ]

    /// The app-wide default resolver. Immutable value, safe to share.
    public static let standard = VideoEngineResolver()

    /// The engine for a described title — lowest tier that can play it.
    /// Falls back to `.avFoundation` if nothing matches (shouldn't happen while
    /// `VLCEngine` is the universal fallback, but keeps the choice total).
    public func resolve(_ descriptor: MediaDescriptor) -> VideoEngineKind {
        engines.first { $0.canPlay(descriptor) }?.kind ?? .avFoundation
    }

    // MARK: Conveniences (mirror the call sites the old enum served)

    /// Engine for a resolved playback URL, decided by scheme then container.
    public func engine(for url: URL) -> VideoEngineKind {
        resolve(MediaDescriptor(url: url))
    }

    /// Engine for an item, from its `streamURL`. No URL ⇒ `.avFoundation`.
    public func engine(for item: MediaItem) -> VideoEngineKind {
        guard let url = item.streamURL else { return .avFoundation }
        return engine(for: url)
    }

    /// Engine for a raw container name (e.g. Plex's `Media.container`), decided
    /// **before** any playback URL exists — used at download time to tell
    /// whether the *original* file would need the fallback engine. `nil`/empty
    /// ⇒ `.avFoundation` (don't restrict on an unknown container).
    public func engine(forContainer container: String?) -> VideoEngineKind {
        resolve(MediaDescriptor(container: container))
    }
}
