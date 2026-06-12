import SwiftUI

/// How strongly a **watched** poster is muted in the grids (#280). The user
/// picks the level in Settings; `AetherCard` reads it from the environment so
/// every poster surface stays consistent without threading a parameter through
/// every call site.
public enum WatchedDimming: String, Codable, CaseIterable, Sendable {
    case subtle
    case medium
    case strong

    public var displayName: String {
        switch self {
        case .subtle: return "Subtle"
        case .medium: return "Medium"
        case .strong: return "Strong"
        }
    }

    /// Artwork saturation — lower = greyer.
    public var saturation: Double {
        switch self {
        case .subtle: return 0.55
        case .medium: return 0.30
        case .strong: return 0.12
        }
    }

    /// Black overlay opacity over the artwork — higher = darker.
    public var blackOpacity: Double {
        switch self {
        case .subtle: return 0.22
        case .medium: return 0.45
        case .strong: return 0.62
        }
    }
}

/// Preset "WATCHED" wordmark opacities (#280). The stored value is a continuous
/// `Double` (an iOS / visionOS slider); these presets back the tvOS picker,
/// where `Slider` isn't available.
public enum WatchedLabelOpacity: String, Codable, CaseIterable, Sendable {
    case faint
    case light
    case medium
    case solid

    public var displayName: String {
        switch self {
        case .faint:  return "Faint"
        case .light:  return "Light"
        case .medium: return "Medium"
        case .solid:  return "Solid"
        }
    }

    public var value: Double {
        switch self {
        case .faint:  return 0.4
        case .light:  return 0.6
        case .medium: return 0.8
        case .solid:  return 1.0
        }
    }
}

/// The watched-poster treatment, injected from the app's playback preferences.
public struct WatchedDisplayConfig: Sendable, Hashable {
    public var dimming: WatchedDimming
    public var showLabel: Bool
    /// Opacity of the "WATCHED" wordmark (0...1).
    public var labelOpacity: Double

    public init(dimming: WatchedDimming = .medium, showLabel: Bool = true, labelOpacity: Double = 0.8) {
        self.dimming = dimming
        self.showLabel = showLabel
        self.labelOpacity = labelOpacity
    }
}

private struct WatchedDisplayKey: EnvironmentKey {
    // Default = medium dim + the "WATCHED" label, so it's clearly visible at
    // 10-foot distance out of the box (#280).
    static let defaultValue = WatchedDisplayConfig()
}

public extension EnvironmentValues {
    var watchedDisplay: WatchedDisplayConfig {
        get { self[WatchedDisplayKey.self] }
        set { self[WatchedDisplayKey.self] = newValue }
    }
}
