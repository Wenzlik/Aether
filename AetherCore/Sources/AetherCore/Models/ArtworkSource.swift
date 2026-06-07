import Foundation

/// A title's artwork as a **source + reference**, able to mint a server-resized
/// URL at any `ArtworkTier` on demand — rather than baking a single fixed-size
/// URL at map time. This is what lets a grid request a 400-px poster while the
/// Detail hero requests a 1920-px backdrop *of the same title*, and it pins the
/// artwork to a concrete source so a unified title's image identity is stable.
///
/// The per-tier URL construction (Plex `/photo/:/transcode`, Jellyfin
/// `fillWidth`/`format=Webp`) lives here — the single source of truth both
/// connectors build into. Cross-platform (module rule #4).
public struct ArtworkSource: Sendable, Hashable {
    public enum Provider: Sendable, Hashable { case plex, jellyfin }

    public let provider: Provider
    /// Server base URL (scheme + host + port).
    public let base: URL
    /// `X-Plex-Token` (Plex) or `api_key` (Jellyfin). Stripped from cache keys.
    public let token: String
    /// Plex: the raw image path (e.g. `/library/metadata/6/thumb/{ts}`).
    /// Jellyfin: the image endpoint path (e.g. `/Items/{id}/Images/Primary`).
    public let posterPath: String?
    /// Jellyfin Primary image tag (content hash); `nil` for Plex.
    public let posterTag: String?
    public let backdropPath: String?
    public let backdropTag: String?

    public init(
        provider: Provider,
        base: URL,
        token: String,
        posterPath: String?,
        posterTag: String? = nil,
        backdropPath: String?,
        backdropTag: String? = nil
    ) {
        self.provider = provider
        self.base = base
        self.token = token
        self.posterPath = posterPath
        self.posterTag = posterTag
        self.backdropPath = backdropPath
        self.backdropTag = backdropTag
    }

    /// A server-resized poster URL for the given tier (2:3).
    public func posterURL(_ tier: ArtworkTier = .thumbnail) -> URL? {
        url(path: posterPath, tag: posterTag, tier: tier)
    }

    /// A server-resized backdrop URL for the given tier (16:9).
    public func backdropURL(_ tier: ArtworkTier = .backdrop) -> URL? {
        url(path: backdropPath, tag: backdropTag, tier: tier)
    }

    private func url(path: String?, tag: String?, tier: ArtworkTier) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        switch provider {
        case .plex:
            // Photo transcoder: original path in `url=`, token on the outer URL
            // only. minSize=1 fills the box; upscale=0 never enlarges. JPEG only.
            var components = URLComponents(
                url: base.appendingPathComponent("/photo/:/transcode"),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [
                URLQueryItem(name: "url", value: path),
                URLQueryItem(name: "width", value: String(tier.pixelWidth)),
                URLQueryItem(name: "height", value: String(tier.pixelHeight)),
                URLQueryItem(name: "minSize", value: "1"),
                URLQueryItem(name: "upscale", value: "0"),
                URLQueryItem(name: "X-Plex-Token", value: token),
            ]
            return components?.url

        case .jellyfin:
            // Jellyfin needs the image tag; without it there's no image to size.
            guard let tag else { return nil }
            var components = URLComponents(
                url: base.appendingPathComponent(path),
                resolvingAgainstBaseURL: false
            )
            let quality = (tier == .thumbnail || tier == .still) ? "85" : "90"
            components?.queryItems = [
                URLQueryItem(name: "api_key", value: token),
                URLQueryItem(name: "tag", value: tag),
                URLQueryItem(name: "fillWidth", value: String(tier.pixelWidth)),
                URLQueryItem(name: "fillHeight", value: String(tier.pixelHeight)),
                URLQueryItem(name: "quality", value: quality),
                URLQueryItem(name: "format", value: "Webp"),
            ]
            return components?.url
        }
    }
}
