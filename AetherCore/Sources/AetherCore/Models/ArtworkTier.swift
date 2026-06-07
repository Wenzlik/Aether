import Foundation

/// The size a piece of artwork is requested at, so the **server** resizes it
/// before sending instead of the app downloading a full-resolution original and
/// downsampling locally (which saved memory but no bandwidth — see 0.5.7).
///
/// Widths are the server-side request targets in pixels; heights follow the
/// artwork's natural aspect (2:3 poster, 16:9 backdrop / still). Pair each tier
/// with a matching `maxPixel` at the call site so `AetherImageCache`'s local
/// downsample doesn't shrink a large hero back down. Cross-platform on purpose
/// (module rule #4) — the connectors that build URLs live in AetherCore.
public enum ArtworkTier: Sendable, Hashable {
    /// Rails, grids, cards — the dominant artwork surface (2:3 poster).
    case thumbnail
    /// The detail screen's poster (2:3).
    case detail
    /// Episode-row still (16:9, shown small).
    case still
    /// Hero / featured backdrop (16:9) — phone / iPad / regular.
    case backdrop
    /// Full-screen hero backdrop (16:9) on tvOS / visionOS.
    case backdropLarge

    /// Server-side resize target width, in pixels.
    public var pixelWidth: Int {
        switch self {
        case .thumbnail:     return 400
        case .detail:        return 600
        case .still:         return 500
        case .backdrop:      return 1200
        case .backdropLarge: return 1920
        }
    }

    /// Server-side resize target height, in pixels (2:3 posters, 16:9 backdrops).
    public var pixelHeight: Int {
        switch self {
        case .thumbnail:     return 600
        case .detail:        return 900
        case .still:         return 282
        case .backdrop:      return 675
        case .backdropLarge: return 1080
        }
    }

    /// Longest-edge pixel ceiling for the local `AetherImageCache` downsample,
    /// so a tier's image isn't shrunk below what it was requested at. Defaults
    /// to the request width (the cache only ever shrinks, never upscales).
    public var maxPixel: CGFloat { CGFloat(pixelWidth) }
}
