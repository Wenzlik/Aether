import Foundation

/// App-wide Cinema Mode preferences for the visionOS immersive cinema — the
/// user's **default** screen size + seat, the **environment**, and the
/// auto-enter / remember-last behaviour toggles.
///
/// UserDefaults-backed and `@Observable`, mirroring `PlaybackPreferencesStore`.
/// Cross-platform on purpose (module rule #4): every value round-trips on any
/// device — the preferences can be chosen in Settings anywhere — even though
/// only visionOS renders the cinema.
///
/// **Default vs. last-used.** `defaultScreenPreset` / `defaultSeat` are the
/// stable choices the user sets in Settings. `screenPreset` / `seat` track the
/// *last-used* configuration (written by `CinemaManager` when the user changes
/// size/seat live during playback). `rememberLastSetup` decides which the cinema
/// opens with — see `entryScreenPreset` / `entrySeat`.
@Observable
@MainActor
public final class CinemaPreferencesStore {

    // MARK: - Default (Settings-chosen, stable)

    /// The screen-size preset the cinema opens with by default. Default `.medium`.
    public var defaultScreenPreset: CinemaScreenPreset {
        didSet { defaults.set(defaultScreenPreset.rawValue, forKey: Keys.defaultScreenPreset) }
    }

    /// The seat (row) the cinema opens with by default. Default `.middle`.
    public var defaultSeat: CinemaSeat {
        didSet { defaults.set(defaultSeat.rawValue, forKey: Keys.defaultSeat) }
    }

    /// The spatial environment Cinema Mode renders. Only `CinemaEnvironment`s
    /// that are `isAvailable` should be offered in the picker. Default
    /// `.darkTheater`.
    public var environment: CinemaEnvironment {
        didSet { defaults.set(environment.rawValue, forKey: Keys.environment) }
    }

    // MARK: - Behaviour toggles

    /// When `true`, playback that starts on visionOS enters Cinema Mode directly
    /// instead of the windowed player. Default `false`.
    public var autoEnterCinema: Bool {
        didSet { defaults.set(autoEnterCinema, forKey: Keys.autoEnterCinema) }
    }

    /// When `true`, the cinema reopens with the *last-used* screen size + seat
    /// (`screenPreset` / `seat`) instead of the Settings defaults. Default
    /// `false` — the explicit defaults win unless the user opts in.
    public var rememberLastSetup: Bool {
        didSet { defaults.set(rememberLastSetup, forKey: Keys.rememberLastSetup) }
    }

    // MARK: - Last-used (written live by CinemaManager)

    /// The screen-size preset most recently used in the cinema. Written when the
    /// user changes size live during playback; read at entry only when
    /// `rememberLastSetup` is on.
    public var screenPreset: CinemaScreenPreset {
        didSet { defaults.set(screenPreset.rawValue, forKey: Keys.screenPreset) }
    }

    /// The seat most recently used in the cinema. See `screenPreset`.
    public var seat: CinemaSeat {
        didSet { defaults.set(seat.rawValue, forKey: Keys.seat) }
    }

    // MARK: - Resolved entry values

    /// The screen size the cinema should open with right now — last-used when
    /// `rememberLastSetup`, otherwise the Settings default.
    public var entryScreenPreset: CinemaScreenPreset {
        rememberLastSetup ? screenPreset : defaultScreenPreset
    }

    /// The seat the cinema should open with right now. See `entryScreenPreset`.
    public var entrySeat: CinemaSeat {
        rememberLastSetup ? seat : defaultSeat
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let screenPreset = "cinema.screenPreset"
        static let seat = "cinema.seat"
        static let defaultScreenPreset = "cinema.defaultScreenPreset"
        static let defaultSeat = "cinema.defaultSeat"
        static let environment = "cinema.environment"
        static let autoEnterCinema = "cinema.autoEnterCinema"
        static let rememberLastSetup = "cinema.rememberLastSetup"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        func preset(_ key: String) -> CinemaScreenPreset? {
            defaults.string(forKey: key).flatMap(CinemaScreenPreset.init(rawValue:))
        }
        func seatValue(_ key: String) -> CinemaSeat? {
            defaults.string(forKey: key).flatMap(CinemaSeat.init(rawValue:))
        }

        self.screenPreset = preset(Keys.screenPreset) ?? .default
        self.seat = seatValue(Keys.seat) ?? .default
        self.defaultScreenPreset = preset(Keys.defaultScreenPreset) ?? .default
        self.defaultSeat = seatValue(Keys.defaultSeat) ?? .default
        self.environment = defaults.string(forKey: Keys.environment)
            .flatMap(CinemaEnvironment.init(rawValue:)) ?? .default
        self.autoEnterCinema = defaults.bool(forKey: Keys.autoEnterCinema)
        self.rememberLastSetup = defaults.bool(forKey: Keys.rememberLastSetup)
    }
}
