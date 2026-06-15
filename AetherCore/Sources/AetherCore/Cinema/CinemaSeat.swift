import Foundation

/// Where the viewer "sits" in the immersive cinema — the Apple TV+ style row
/// control. Since the system fixes the viewer at the immersive-space origin, a
/// seat is realised by sliding the *theater* toward or away from the viewer
/// along Z (the screen + room move; the viewer stays put).
///
/// Cross-platform on purpose (module rule #4): the value round-trips on any
/// device even though only visionOS renders the cinema.
public enum CinemaSeat: String, Sendable, Hashable, CaseIterable, Codable {
    /// Closest to the screen.
    case front
    /// The authored layout — the default.
    case middle
    /// Farthest from the screen.
    case back

    public var displayName: String {
        switch self {
        case .front:  return "Front"
        case .middle: return "Middle"
        case .back:   return "Back"
        }
    }

    /// Z translation (metres) applied to the theater root. `+Z` slides the room
    /// toward the viewer (front row — screen closer); `-Z` away (back row).
    /// `.middle` is `0` so it reads at the authored layout. First-pass values —
    /// tune on device.
    public var zOffsetMetres: Float {
        switch self {
        case .front:  return 2.5
        case .middle: return 0.0
        case .back:   return -2.5
        }
    }

    /// Y translation (metres) applied to the theater root — stadium rake. Moving
    /// the room *down* (`-Y`) lifts the viewer relative to it, so each row back
    /// sits a little higher and looks slightly *down* at the screen.
    ///
    /// Absolute *vertical placement* is no longer this control's job — the
    /// immersive layer anchors the screen by its bottom edge (#357). So the rake
    /// only ever holds the room at or below the authored layout (front `0`, never
    /// `+Y`): front raised the screen and was the worst "look up" case, so front
    /// now sits level and the room only descends from there. First-pass values —
    /// tune on device.
    public var yOffsetMetres: Float {
        switch self {
        case .front:  return 0.0
        case .middle: return -0.2
        case .back:   return -0.4
        }
    }

    /// The order the seat switcher presents, closest → farthest.
    public static let ordered: [CinemaSeat] = [.front, .middle, .back]

    /// App-wide default until the user picks one (then `CinemaPreferences`
    /// remembers it).
    public static let `default`: CinemaSeat = .middle
}
