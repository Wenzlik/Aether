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

    /// Hide fully-watched titles from the discovery surfaces — Home's
    /// Recently Added / Released rails and Discover — so they show what's
    /// still ahead, not what's done. Library is the complete catalog and is
    /// never filtered. Default `true`.
    public var hideWatchedInDiscovery: Bool {
        didSet { defaults.set(hideWatchedInDiscovery, forKey: Keys.hideWatched) }
    }

    /// How strongly watched posters are dimmed/desaturated in the grids (#280).
    /// Default `.medium`.
    public var watchedDimming: WatchedDimming {
        didSet { defaults.set(watchedDimming.rawValue, forKey: Keys.watchedDimming) }
    }

    /// Whether the centered "WATCHED" label is drawn over finished posters
    /// (#280). Default `true`.
    public var watchedShowLabel: Bool {
        didSet { defaults.set(watchedShowLabel, forKey: Keys.watchedShowLabel) }
    }

    /// How translucent the "WATCHED" wordmark is, `0.15...1.0` (#280). Continuous
    /// (a Settings slider on iOS); default `0.8`.
    public var watchedLabelOpacity: Double {
        didSet {
            watchedLabelOpacity = Self.clampOpacity(watchedLabelOpacity)
            defaults.set(watchedLabelOpacity, forKey: Keys.watchedLabelOpacity)
        }
    }

    /// Keep the wordmark visible-but-faint at the low end (0 would be invisible,
    /// which is what the Show-Label toggle is for).
    public static let minLabelOpacity: Double = 0.15
    static func clampOpacity(_ value: Double) -> Double { min(1.0, max(minLabelOpacity, value)) }

    /// Bundled into the value injected as `\.watchedDisplay`.
    public var watchedDisplayConfig: WatchedDisplayConfig {
        WatchedDisplayConfig(dimming: watchedDimming, showLabel: watchedShowLabel, labelOpacity: watchedLabelOpacity)
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
        static let hideWatched = "display.hideWatchedInDiscovery"
        static let watchedDimming = "display.watchedDimming"
        static let watchedShowLabel = "display.watchedShowLabel"
        static let watchedLabelOpacity = "display.watchedLabelOpacity"
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
        // `object(forKey:)` so a missing key → default true (hide watched).
        self.hideWatchedInDiscovery = (defaults.object(forKey: Keys.hideWatched) as? Bool) ?? true
        self.watchedDimming = defaults.string(forKey: Keys.watchedDimming).flatMap(WatchedDimming.init) ?? .medium
        self.watchedShowLabel = (defaults.object(forKey: Keys.watchedShowLabel) as? Bool) ?? true
        // `object(forKey:) as? Double` so a missing key (or the old string enum
        // value from a prior build) cleanly falls back to the 0.8 default.
        self.watchedLabelOpacity = (defaults.object(forKey: Keys.watchedLabelOpacity) as? Double).map(Self.clampOpacity) ?? 0.8
    }
}

public extension PlaybackPreferencesStore {
    /// Apply the user's playback defaults to a hydrated item: audio by language
    /// match, subtitles by language match (or "off"), and the default quality.
    /// Extracted from DetailView so EVERY path that opens a player — Detail's
    /// Play, the fallback hydrate, and Auto-Play-Next — applies the same
    /// defaults (#68: next episodes used to revert to the container default).
    func applied(to item: MediaItem) -> MediaItem {
        var result = item

        // Audio: match by language code (case-insensitive). Only override
        // when the title has a track in the preferred language.
        if let preferred = defaultAudioLanguage?.lowercased(),
           let track = result.audioTracks.first(where: {
               $0.languageCode?.lowercased() == preferred
           }) {
            result = result.selectingAudioTrack(track)
        }

        // Subtitles: "off" disables subs entirely; nil leaves whatever the
        // source picked; a language code selects the first matching track.
        if let preferred = defaultSubtitleLanguage {
            if preferred == "off" {
                result = result.selectingSubtitleTrack(nil)
            } else if let track = result.subtitleTracks.first(where: {
                $0.languageCode?.lowercased() == preferred.lowercased()
            }) {
                result = result.selectingSubtitleTrack(track)
            }
        }

        // Quality: always applied. The MediaItem default is `.original`,
        // but most users want the picker to open on whatever they chose
        // last as their everywhere-default.
        result = result.selectingQuality(defaultQuality)

        return result
    }

    /// Configure the **next episode** for Auto-Play-Next: the session's live
    /// context wins — the language you're hearing and the subtitle state you
    /// chose carry over to the next episode — with the app defaults as the
    /// base. Quality follows the current session (#68).
    func appliedToNextEpisode(_ next: MediaItem, continuing current: MediaItem) -> MediaItem {
        var result = applied(to: next)

        // Carry the playing audio language over (an explicit in-session pick
        // beats the app default).
        if let language = current.selectedAudioTrack?.languageCode?.lowercased(),
           let track = result.audioTracks.first(where: {
               $0.languageCode?.lowercased() == language
           }) {
            result = result.selectingAudioTrack(track)
        }

        // Subtitles: carry the current language; an explicitly-off state
        // (no selected track despite available tracks) stays off.
        if let language = current.selectedSubtitleTrack?.languageCode?.lowercased() {
            if let track = result.subtitleTracks.first(where: {
                $0.languageCode?.lowercased() == language
            }) {
                result = result.selectingSubtitleTrack(track)
            }
        } else if current.selectedSubtitleTrackID == nil, !current.subtitleTracks.isEmpty {
            result = result.selectingSubtitleTrack(nil)
        }

        // Quality continues from the session, not the default.
        result = result.selectingQuality(current.selectedQuality)

        return result
    }
}
