import SwiftUI

/// The app's UI language, overridable in-app independent of the system language
/// (#312). Applied at the app root via `.environment(\.locale, …)`, which drives
/// SwiftUI `Text` / String Catalog lookups live (the same mechanism Xcode
/// previews use to switch localizations) — no relaunch.
///
/// **Adding a language is just translating it.** The selectable list is derived
/// from the bundle's actual localizations (`Bundle.main.localizations`, i.e. the
/// compiled String Catalog), so translating `Localizable.xcstrings` into a new
/// language makes it appear here automatically — no code change, no new `case`.
public struct AppLanguage: Identifiable, Hashable, Sendable {
    /// BCP-47 code of the language, or `nil` = follow the system language.
    public let code: String?

    public init(code: String?) { self.code = code }

    public var id: String { code ?? "system" }

    /// Follow the device language.
    public static let system = AppLanguage(code: nil)

    /// **System** first, then every UI language the app bundle ships, ordered by
    /// display name. This is the whole reason adding a language needs no code.
    public static var available: [AppLanguage] {
        let languages = Bundle.main.localizations
            .filter { $0 != "Base" }
            .map { AppLanguage(code: $0) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        return [.system] + languages
    }

    /// The locale to apply, or `nil` for "follow the system language".
    public var locale: Locale? { code.map(Locale.init(identifier:)) }

    /// Picker label. A real language shows its **endonym** (its own name — e.g.
    /// "Čeština", "English", "Deutsch" — stable regardless of the active UI
    /// language); `system` localizes through the catalog.
    public var displayName: String {
        guard let code else {
            return String(localized: "System", comment: "Language option: follow the device language")
        }
        let locale = Locale(identifier: code)
        let name = locale.localizedString(forLanguageCode: code)
            ?? locale.localizedString(forIdentifier: code)
            ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}

/// Single source of truth for the chosen UI language. Persisted in UserDefaults;
/// applied at the app root. Mirrors `AppearancePreferenceStore`.
@Observable
@MainActor
public final class LanguagePreferenceStore {

    public var preference: AppLanguage {
        didSet { defaults.set(preference.id, forKey: Keys.language) }
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
        self.preference = Self.stored(from: defaults.string(forKey: Keys.language))
    }

    /// Read the persisted choice, migrating the legacy enum rawValues
    /// (`"english"` / `"czech"`) from the pre-#320 build to language codes.
    private static func stored(from raw: String?) -> AppLanguage {
        switch raw {
        case nil, "system":   return .system
        case "english":       return AppLanguage(code: "en")
        case "czech":         return AppLanguage(code: "cs")
        case let .some(code): return AppLanguage(code: code)
        }
    }
}
