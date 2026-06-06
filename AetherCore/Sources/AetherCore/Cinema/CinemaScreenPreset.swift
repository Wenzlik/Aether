import Foundation

/// How big the cinema screen is. The screen is the hero (see
/// `docs/next-steps/visionos-cinema.md` → *Screen System*), so this is the
/// control the user reaches for most often.
///
/// A pure value type: it carries the *intent* (a target physical width) and a
/// `relativeScale` the RealityKit layer multiplies into the screen entity. The
/// absolute metres-to-entity mapping is refined in the screen-presets phase;
/// the scaffold only needs the four steps to read distinctly different sizes.
///
/// Cross-platform on purpose — iOS / tvOS never build the immersive views, but
/// the preset still compiles there (module rule #4) so a future "preferred
/// screen size" setting can round-trip on any device.
public enum CinemaScreenPreset: String, Sendable, Hashable, CaseIterable, Codable {
    /// Comfortable viewing. The default.
    case medium
    /// Cinema-like.
    case large
    /// Massive — the Vision Pro showcase mode.
    case imax
    /// Largest supported scale. Experimental.
    case wall

    public var displayName: String {
        switch self {
        case .medium: return "Medium"
        case .large:  return "Large"
        case .imax:   return "IMAX"
        case .wall:   return "Wall"
        }
    }

    /// Target screen width in metres. Authored as intent; the immersive layer
    /// reads `relativeScale` today and graduates to honouring this exact width
    /// in the screen-presets phase.
    public var widthMetres: Float {
        switch self {
        case .medium: return 3.0
        case .large:  return 5.0
        case .imax:   return 8.0
        case .wall:   return 12.0
        }
    }

    /// Scale applied to the screen entity relative to its `.medium` baseline.
    /// `.medium` is `1.0` so the default reads at the entity's natural size;
    /// the others widen from there. Derived from `widthMetres` so the two
    /// stay in lockstep if the metres are retuned.
    public var relativeScale: Float {
        widthMetres / CinemaScreenPreset.medium.widthMetres
    }

    /// The Reality Composer Pro scene (in `RealityKitContent.rkassets`) that
    /// holds this preset's authored environment — a `DockingRegion` sized to
    /// `widthMetres` plus a reflective floor. Authored later; the loader falls
    /// back to the procedural Dark Theater until the scene exists.
    public var sceneName: String {
        switch self {
        case .medium: return "CinemaMedium"
        case .large:  return "CinemaLarge"
        case .imax:   return "CinemaIMAX"
        case .wall:   return "CinemaWall"
        }
    }

    /// The immersive-space id for this preset. Distinct per preset because the
    /// docked screen's size/placement lives in each preset's *own* environment,
    /// chosen through the system `immersiveEnvironmentPicker` (a `DockingRegion`
    /// is ignored unless its environment is the player's active one).
    public var spaceID: String { "AetherCinema.\(rawValue)" }

    /// The order the size switcher presents, smallest → largest.
    public static let ordered: [CinemaScreenPreset] = [.medium, .large, .imax, .wall]

    /// The app-wide default until the user picks one (then `CinemaPreferences`
    /// remembers it).
    public static let `default`: CinemaScreenPreset = .medium
}
