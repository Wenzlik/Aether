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
        // Sizing is relative to the authored dock (= `.medium`, ×1.0). Tuned on
        // device 2026-06-07: Medium/Large felt right, IMAX ok; Wall kept reading
        // too big (×4.0 → ×3.0 → ×2.67). relativeScale now 1.0 / 1.67 / 2.33 / 2.67.
        case .imax:   return 7.0
        case .wall:   return 8.0
        }
    }

    /// Scale applied to the screen entity relative to its `.medium` baseline.
    /// `.medium` is `1.0` so the default reads at the entity's natural size;
    /// the others widen from there. Derived from `widthMetres` so the two
    /// stay in lockstep if the metres are retuned.
    ///
    /// One authored scene, sized in code: `.medium` (`1.0`) reads at the size
    /// of the `DockingRegion` authored in `AetherDarkTheater.usda`; the
    /// immersive layer multiplies this into the dock entity's transform so the
    /// larger presets widen the docked screen without a per-preset `.usda`.
    public var relativeScale: Float {
        widthMetres / CinemaScreenPreset.medium.widthMetres
    }

    /// The order the size switcher presents, smallest → largest.
    public static let ordered: [CinemaScreenPreset] = [.medium, .large, .imax, .wall]

    /// The next size in `ordered`, wrapping `wall → medium`. Drives the
    /// single-button "Screen" cycler in the native transport bar: each tap steps
    /// up one size, then wraps to the smallest.
    public var next: CinemaScreenPreset {
        let all = Self.ordered
        let i = all.firstIndex(of: self) ?? 0
        return all[(i + 1) % all.count]
    }

    /// The app-wide default until the user picks one (then `CinemaPreferences`
    /// remembers it).
    public static let `default`: CinemaScreenPreset = .medium
}
