import SwiftUI

/// Design tokens for Aether's visual language.
///
/// Numeric values are documented in `docs/ux/DESIGN_PRINCIPLES.md`. Never hard-code a
/// color, font, spacing, radius, or duration in a view — pull it from here.
public enum AetherDesign {

    // MARK: - Spacing

    public enum Spacing {
        public static let xxs: CGFloat = 4
        public static let xs: CGFloat = 8
        public static let s: CGFloat = 12
        public static let m: CGFloat = 16
        public static let l: CGFloat = 24
        public static let xl: CGFloat = 32
        public static let xxl: CGFloat = 48
    }

    // MARK: - Radii

    public enum Radius {
        public static let card: CGFloat = 12
        public static let cardTV: CGFloat = 16
        public static let sheet: CGFloat = 20
    }

    // MARK: - Motion

    public enum Motion {
        public static let content: Animation = .easeInOut(duration: 0.25)
        public static let hero: Animation = .easeInOut(duration: 0.35)
        public static let focus: Animation = .spring(response: 0.18, dampingFraction: 0.85)
        public static let card: Animation = .spring(response: 0.40, dampingFraction: 0.85)
    }

    // MARK: - Color

    public enum Palette {
        public static let background = Color.black
        public static let surface = Color(white: 0.08)
        public static let textPrimary = Color.white
        public static let textSecondary = Color.white.opacity(0.65)
        public static let textTertiary = Color.white.opacity(0.40)
        public static let accent = Color(red: 0.78, green: 0.78, blue: 0.86)
    }

    // MARK: - Typography

    public enum Typography {
        public static let heroTitle: Font = .system(.largeTitle, design: .default, weight: .bold)
        public static let sectionTitle: Font = .system(.title2, design: .default, weight: .semibold)
        public static let cardTitle: Font = .system(.headline, design: .default, weight: .medium)
        public static let body: Font = .system(.body, design: .default, weight: .regular)
        public static let metadata: Font = .system(.subheadline, design: .default, weight: .medium)
        public static let caption: Font = .system(.caption, design: .default, weight: .regular)
    }
}
