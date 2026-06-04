import SwiftUI

/// User's chosen colour scheme for the app. Mirrors Apple's standard
/// **System / Dark / Light** triplet (Settings → Display & Brightness).
public enum AppearancePreference: String, CaseIterable, Codable, Sendable {
    case system
    case dark
    case light

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .dark:   return "Dark"
        case .light:  return "Light"
        }
    }

    /// SwiftUI `ColorScheme` override to pass to `.preferredColorScheme(_:)`.
    /// `nil` means *don't override* — let the system value flow through.
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark:   return .dark
        case .light:  return .light
        }
    }
}

/// Single source of truth for the user's chosen appearance. Persisted in
/// UserDefaults; applied at the app root via `.preferredColorScheme(_:)`.
///
/// Selecting `.light` while the dark-themed `AetherDesign.Palette` tokens
/// are still hard-coded looks visually broken — the Palette redesign that
/// makes Light mode actually beautiful is a separate piece of work. The
/// picker UI ships first so the preference plumbing is in place; visual
/// Light support follows when the tokens are redone with adaptive colours.
@Observable
@MainActor
public final class AppearancePreferenceStore {

    public var preference: AppearancePreference {
        didSet {
            defaults.set(preference.rawValue, forKey: Keys.appearance)
        }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let appearance = "appearance.preference"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.string(forKey: Keys.appearance),
           let value = AppearancePreference(rawValue: raw) {
            self.preference = value
        } else {
            self.preference = .system
        }
    }
}
