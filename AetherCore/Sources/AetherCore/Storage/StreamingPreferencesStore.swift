import Foundation

/// User preferences for the **Netflix availability** feature (#360) — whether to
/// show it at all, and which country's availability to use.
///
/// Opt-in: off by default. UserDefaults-backed and `@Observable`, mirroring
/// `CinemaPreferencesStore`. Cross-platform (module rule #4) — every value
/// round-trips on any device.
@Observable
@MainActor
public final class StreamingPreferencesStore {

    /// Master switch for the whole feature. When `false`, no badges, no Netflix
    /// rails, no "Play on Netflix". Default `false`.
    public var netflixAvailabilityEnabled: Bool {
        didSet { defaults.set(netflixAvailabilityEnabled, forKey: Keys.netflixEnabled) }
    }

    /// Whether **Netflix-only** titles (not in the user's library, available
    /// only on Netflix) appear as posters in Discover / Search. When `false`,
    /// only **owned** titles get the "on Netflix" badge — the library stays
    /// "what you own" and isn't padded with Netflix-only entries (#360). Default
    /// `true`. No effect when `netflixAvailabilityEnabled` is off.
    public var showNetflixOnlyTitles: Bool {
        didSet { defaults.set(showNetflixOnlyTitles, forKey: Keys.showNetflixOnly) }
    }

    /// The ISO-3166 country code availability is checked against (`"US"`,
    /// `"CZ"`, …). `nil` means "follow the device/app region", resolved by the
    /// caller — see `resolvedRegion(default:)`.
    public var region: String? {
        didSet {
            if let region, !region.isEmpty {
                defaults.set(region, forKey: Keys.region)
            } else {
                defaults.removeObject(forKey: Keys.region)
            }
        }
    }

    /// The region to actually query: the user's explicit choice, else the
    /// supplied fallback (the caller passes the app locale's region — never
    /// `Locale.current` blindly, per the localization rules).
    public func resolvedRegion(default fallback: String) -> String {
        let chosen = region?.trimmingCharacters(in: .whitespaces) ?? ""
        return chosen.isEmpty ? fallback.uppercased() : chosen.uppercased()
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let netflixEnabled = "streaming.netflixEnabled"
        static let showNetflixOnly = "streaming.showNetflixOnly"
        static let region = "streaming.region"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.netflixAvailabilityEnabled = defaults.bool(forKey: Keys.netflixEnabled)
        // Defaults to true (show them) — the user can opt out to keep the
        // library/discovery limited to what they own.
        self.showNetflixOnlyTitles = defaults.object(forKey: Keys.showNetflixOnly) as? Bool ?? true
        self.region = defaults.string(forKey: Keys.region)
    }
}
