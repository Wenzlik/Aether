import Foundation

/// The spatial environment Cinema Mode renders around the screen.
///
/// V1 ships exactly one — `darkTheater`, the premium black screening room that
/// becomes the default Aether identity (see
/// `docs/next-steps/visionos-cinema.md` → *Initial Environment*). The future
/// environments are **declared here but not buildable yet**: `isAvailable`
/// gates them off so the type can describe the full roadmap without the
/// RealityKit layer having to render something that doesn't exist.
///
/// Pure value type, cross-platform (module rule #4) so a "preferred
/// environment" preference round-trips on any device even though only visionOS
/// draws it.
public enum CinemaEnvironment: String, Sendable, Hashable, CaseIterable, Codable {
    /// A premium black cinematic space — minimal architecture, dark floor, soft
    /// indirect lighting, restrained violet accents. The V1 environment.
    case darkTheater

    // Future — designed for, not built (spec §Future Roadmap). `isAvailable`
    // is `false` until each lands its own RealityKit builder.
    case nebula
    case deepSpace
    case orbitStation

    public var displayName: String {
        switch self {
        case .darkTheater:  return "Dark Theater"
        case .nebula:       return "Nebula"
        case .deepSpace:    return "Deep Space"
        case .orbitStation: return "Orbit Station"
        }
    }

    /// Whether this environment has a RealityKit builder behind it yet. Only
    /// `darkTheater` is `true` in V1; the size switcher / environment picker
    /// must filter on this so the user can never select an empty space.
    public var isAvailable: Bool {
        self == .darkTheater
    }

    /// Environments the user can actually enter today.
    public static var available: [CinemaEnvironment] {
        allCases.filter(\.isAvailable)
    }

    /// The default environment — Aether's signature identity.
    public static let `default`: CinemaEnvironment = .darkTheater
}
