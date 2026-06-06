import Foundation

/// The size a piece of artwork is requested at, so the **server** resizes it
/// before sending instead of the app downloading a full-resolution original and
/// downsampling locally (which saved memory but no bandwidth — see 0.5.7).
///
/// Widths are the server-side request targets in pixels; heights follow the
/// artwork's natural aspect (2:3 poster, 16:9 backdrop). `backdrop` is capped at
/// 1200 to match `AetherImageCache`'s local downsample ceiling, so the on-disk
/// image isn't larger than the cache will keep (per-platform 1600/1920 heroes +
/// a matching cache ceiling are a later refinement). Cross-platform on purpose
/// (module rule #4) — the connectors that build URLs live in AetherCore.
public enum ArtworkTier: Sendable, Hashable {
    /// Rails, grids, cards — the dominant artwork surface.
    case thumbnail
    /// The detail screen's poster.
    case detail
    /// Hero / featured backdrops.
    case backdrop

    /// Server-side resize target width, in pixels.
    public var pixelWidth: Int {
        switch self {
        case .thumbnail: return 400
        case .detail:    return 600
        case .backdrop:  return 1200
        }
    }

    /// Server-side resize target height, in pixels (2:3 for posters, 16:9 for
    /// the backdrop).
    public var pixelHeight: Int {
        switch self {
        case .thumbnail: return 600
        case .detail:    return 900
        case .backdrop:  return 675
        }
    }
}
