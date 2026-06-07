#if os(iOS)
import SwiftUI
import UIKit

/// The app icons the user can choose in **Settings → App Icon** (iOS / iPadOS;
/// alternate icons aren't supported on tvOS / visionOS). Backed by the system
/// `setAlternateIconName` API, which persists the choice across launches.
enum AetherAppIcon: String, CaseIterable, Identifiable, Sendable {
    /// The primary icon shipped in `AppIcon` (no alternate set).
    case `default`
    /// Gold → blue glass "A" (`AppIconLight.appiconset`).
    case light
    /// Clear glass "A" (`AppIconTinted.appiconset`).
    case tinted

    var id: String { rawValue }

    /// The alternate-icon asset name; `nil` is the primary icon.
    var alternateName: String? {
        switch self {
        case .default: return nil
        case .light:   return "AppIconLight"
        case .tinted:  return "AppIconTinted"
        }
    }

    var displayName: String {
        switch self {
        case .default: return "Default"
        case .light:   return "Light"
        case .tinted:  return "Tinted"
        }
    }
}

/// Reads + sets the active app icon. The system owns persistence (it remembers
/// the alternate icon across launches), so this just mirrors the current value
/// and forwards changes — with an optimistic update that reverts if the system
/// rejects the change.
@MainActor
@Observable
final class AppIconStore {
    private(set) var current: AetherAppIcon
    let isSupported: Bool

    init() {
        isSupported = UIApplication.shared.supportsAlternateIcons
        let name = UIApplication.shared.alternateIconName
        current = AetherAppIcon.allCases.first { $0.alternateName == name } ?? .default
    }

    func select(_ icon: AetherAppIcon) {
        guard isSupported, icon != current else { return }
        let previous = current
        current = icon   // optimistic — the row checkmark flips immediately
        UIApplication.shared.setAlternateIconName(icon.alternateName) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in self?.current = previous }   // revert on failure
        }
    }
}
#endif
