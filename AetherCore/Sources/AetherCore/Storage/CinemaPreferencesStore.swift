import Foundation

/// App-wide Cinema Mode preference — the user's default **screen-size preset**
/// for the visionOS immersive cinema.
///
/// UserDefaults-backed and `@Observable`, mirroring `PlaybackPreferencesStore`.
/// Cross-platform on purpose (module rule #4): the value round-trips on any
/// device — a "preferred screen size" can be chosen in Settings anywhere — even
/// though only visionOS renders the cinema.
@Observable
@MainActor
public final class CinemaPreferencesStore {

    /// The screen-size preset the cinema opens with. Persists across launches.
    /// Default `.medium`.
    public var screenPreset: CinemaScreenPreset {
        didSet { defaults.set(screenPreset.rawValue, forKey: Keys.screenPreset) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let screenPreset = "cinema.screenPreset"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.string(forKey: Keys.screenPreset),
           let value = CinemaScreenPreset(rawValue: raw) {
            self.screenPreset = value
        } else {
            self.screenPreset = .default
        }
    }
}
