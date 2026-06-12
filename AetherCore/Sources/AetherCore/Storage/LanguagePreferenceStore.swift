import SwiftUI

/// The app's UI language, overridable in-app independent of the system language
/// (#312). Applied at the app root via `.environment(\.locale, …)`, which drives
/// SwiftUI `Text` / String Catalog lookups live (the same mechanism Xcode
/// previews use to switch localizations) — no relaunch.
///
/// **Adding a language:** add a `case`, its endonym in `displayName`, and its
/// locale identifier in `locale`. That's it — the Settings picker is data-driven
/// over `allCases`, and the String Catalog supplies the translations.
public enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case system
    case english
    case czech

    /// Picker label. Languages use their **endonym** (their own name, shown the
    /// same regardless of UI language); `system` localizes via the catalog.
    public var displayName: String {
        switch self {
        case .system:  return "System"
        case .english: return "English"
        case .czech:   return "Čeština"
        }
    }

    /// The locale to apply, or `nil` for "follow the system language".
    public var locale: Locale? {
        switch self {
        case .system:  return nil
        case .english: return Locale(identifier: "en")
        case .czech:   return Locale(identifier: "cs")
        }
    }
}

/// Single source of truth for the chosen UI language. Persisted in UserDefaults;
/// applied at the app root. Mirrors `AppearancePreferenceStore`.
@Observable
@MainActor
public final class LanguagePreferenceStore {

    public var preference: AppLanguage {
        didSet { defaults.set(preference.rawValue, forKey: Keys.language) }
    }

    /// The locale to hand `.environment(\.locale, …)`: the chosen language, or
    /// the live system locale when following the system.
    public var resolvedLocale: Locale {
        preference.locale ?? Locale.autoupdatingCurrent
    }

    private let defaults: UserDefaults
    private enum Keys { static let language = "ui.language" }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.string(forKey: Keys.language), let value = AppLanguage(rawValue: raw) {
            self.preference = value
        } else {
            self.preference = .system
        }
    }
}
