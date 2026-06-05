import Foundation

/// How a skip segment (intro / credits) is handled during playback.
public enum SkipMode: String, CaseIterable, Sendable, Hashable {
    /// Show a "Skip …" button while inside the segment (default).
    case button
    /// Seek past the segment automatically, no button.
    case automatically
    /// Don't surface the segment at all.
    case off

    public var displayName: String {
        switch self {
        case .button:         return "Show Button"
        case .automatically:  return "Automatically"
        case .off:            return "Off"
        }
    }
}

/// App-wide default preferences for playback — what the user has chosen as
/// their "always start with this" picks for **quality**, **audio language**,
/// and **subtitle language**.
///
/// Distinct from `LibraryPreferencesStore`:
/// - `LibraryPreferencesStore` (Keychain, per-library) holds UI choices
///   tied to a *specific* library on a *specific* server (sort order).
/// - This store (UserDefaults, app-global) holds *playback* defaults that
///   apply across every title and every source.
///
/// **How it's consumed.** `DetailView` reads these defaults when it builds
/// its Audio / Subtitle / Quality pickers. If the current title has a
/// matching audio / subtitle track in the user's preferred language, that
/// track is pre-selected (overriding the source's own default); otherwise
/// the source default stands. The user's per-title choice on Detail still
/// wins for that play session — defaults are the *seed*, not a lock.
///
/// UserDefaults (not Keychain) because these aren't secrets and we want them
/// readable across the app's main process without an actor hop. `@Observable`
/// so SwiftUI views (Settings pickers, Detail) re-render on change.
@Observable
@MainActor
public final class PlaybackPreferencesStore {

    /// Default quality the Detail screen's Quality picker opens to. Persists
    /// across launches via UserDefaults. **Default value:**
    /// `.convertAutomatically` — matches Plex Web's out-of-the-box behaviour
    /// where the server decides what to send. A user who knows their network
    /// will direct-play everything can flip this to `.original`.
    public var defaultQuality: PlaybackQuality {
        didSet {
            defaults.set(defaultQuality.rawValue, forKey: Keys.quality)
        }
    }

    /// BCP-47 audio language code (`"en"`, `"cs"`, `"ja"`, …). `nil` means
    /// "follow the source's default" — Plex / Jellyfin pick their own
    /// preferred track per item and this store stays out of the way. When
    /// set, `DetailView` looks for a matching audio stream on the loaded
    /// item; if one exists, it becomes the picker's initial value.
    public var defaultAudioLanguage: String? {
        didSet {
            if let value = defaultAudioLanguage {
                defaults.set(value, forKey: Keys.audio)
            } else {
                defaults.removeObject(forKey: Keys.audio)
            }
        }
    }

    /// BCP-47 subtitle language code, the literal `"off"` to start with
    /// subtitles disabled, or `nil` to follow the source's default. The
    /// "off" sentinel is distinguished from `nil` because *explicitly off*
    /// is a real preference (a user who doesn't want subs) — different from
    /// *not specified* (let Plex pick).
    public var defaultSubtitleLanguage: String? {
        didSet {
            if let value = defaultSubtitleLanguage {
                defaults.set(value, forKey: Keys.subtitle)
            } else {
                defaults.removeObject(forKey: Keys.subtitle)
            }
        }
    }

    /// How to handle an intro/recap segment. Default `.button`.
    public var skipIntro: SkipMode {
        didSet { defaults.set(skipIntro.rawValue, forKey: Keys.skipIntro) }
    }

    /// How to handle a credits/outro segment. Default `.button`.
    public var skipCredits: SkipMode {
        didSet { defaults.set(skipCredits.rawValue, forKey: Keys.skipCredits) }
    }

    /// Auto-play the next episode when an episode reaches its credits / end.
    /// Default `true`.
    public var autoPlayNext: Bool {
        didSet { defaults.set(autoPlayNext, forKey: Keys.autoPlayNext) }
    }

    /// Seconds the "Next Episode" countdown runs before auto-advancing.
    /// One of 5 / 10 / 15. Default `10`.
    public var nextEpisodeCountdown: Int {
        didSet { defaults.set(nextEpisodeCountdown, forKey: Keys.countdown) }
    }

    /// Allowed countdown lengths, for the Settings picker.
    public static let countdownOptions = [5, 10, 15]

    private let defaults: UserDefaults

    private enum Keys {
        static let quality = "playback.defaultQuality"
        static let audio = "playback.defaultAudioLanguage"
        static let subtitle = "playback.defaultSubtitleLanguage"
        static let skipIntro = "playback.skipIntro"
        static let skipCredits = "playback.skipCredits"
        static let autoPlayNext = "playback.autoPlayNext"
        static let countdown = "playback.nextEpisodeCountdown"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let raw = defaults.string(forKey: Keys.quality),
           let value = PlaybackQuality(rawValue: raw) {
            self.defaultQuality = value
        } else {
            self.defaultQuality = .convertAutomatically
        }

        self.defaultAudioLanguage = defaults.string(forKey: Keys.audio)
        self.defaultSubtitleLanguage = defaults.string(forKey: Keys.subtitle)

        self.skipIntro = defaults.string(forKey: Keys.skipIntro).flatMap(SkipMode.init) ?? .button
        self.skipCredits = defaults.string(forKey: Keys.skipCredits).flatMap(SkipMode.init) ?? .button
        // `object(forKey:)` so a missing key → default true (not false).
        self.autoPlayNext = (defaults.object(forKey: Keys.autoPlayNext) as? Bool) ?? true
        let savedCountdown = defaults.integer(forKey: Keys.countdown)
        self.nextEpisodeCountdown = Self.countdownOptions.contains(savedCountdown) ? savedCountdown : 10
    }
}
