import SwiftUI

/// Design tokens for Aether's visual language — its first real visual identity:
/// a calm, cinematic "personal cinema" look built on a violet brand and near
/// black surfaces. Numeric values + rationale live in
/// `docs/ux/DESIGN_PRINCIPLES.md`. Never hard-code a colour, gradient, font,
/// spacing, radius, or duration in a view — pull it from here.
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

    // MARK: - Color (the Aether brand palette)

    /// `Palette` is the canonical colour namespace used across the app. The
    /// brand accent is **Aether Violet**; surfaces are near-black zinc tones for
    /// an OLED-friendly cinematic base.
    public enum Palette {
        // Brand accents
        /// Aether Violet — the primary accent (focus, selection, primary action).
        public static let accent = Color(hex: 0x8B5CF6)
        /// Aether Indigo — secondary accent, gradient partner.
        public static let accentIndigo = Color(hex: 0x6366F1)
        /// Aether Aurora — hero accent, the brightest brand tone.
        public static let accentAurora = Color(hex: 0xA855F7)

        // Surfaces (near-black zinc)
        public static let background = Color(hex: 0x09090B)
        public static let surface = Color(hex: 0x18181B)
        public static let surfaceElevated = Color(hex: 0x27272A)
        public static let separator = Color.white.opacity(0.10)

        // Text
        public static let textPrimary = Color(hex: 0xFAFAFA)
        public static let textSecondary = Color(hex: 0xA1A1AA)
        public static let textTertiary = Color(hex: 0x71717A)

        // Semantic
        public static let success = Color(hex: 0x22C55E)
        public static let warning = Color(hex: 0xF59E0B)
        public static let error = Color(hex: 0xEF4444)

        /// The colour of the soft violet focus glow (used as a shadow colour on
        /// focused cards / buttons / rows). Replaces flat black focus shadows.
        public static let focusGlow = accent
    }

    /// Convenience alias so new code can read `AetherDesign.Colors.accent` per
    /// the brand-system naming, while existing call sites keep using `Palette`.
    public typealias Colors = Palette

    // MARK: - Gradients

    /// Brand gradients. Computed so they don't pin global state under strict
    /// concurrency, and cheap to build at the call site.
    public enum Gradients {
        /// Hero / featured wash — indigo → aurora, the signature brand sweep.
        public static var aurora: LinearGradient {
            LinearGradient(
                colors: [Palette.accentIndigo, Palette.accentAurora],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        /// Progress fill (Continue Watching bars, scrubbers).
        public static var progress: LinearGradient {
            LinearGradient(
                colors: [Palette.accentIndigo, Palette.accentAurora],
                startPoint: .leading,
                endPoint: .trailing
            )
        }

        /// Whole-screen atmosphere: a faint violet glow at the top fading into
        /// the near-black background. Calm, not loud.
        public static var background: LinearGradient {
            LinearGradient(
                stops: [
                    .init(color: Palette.accent.opacity(0.12), location: 0.0),
                    .init(color: Palette.background, location: 0.45),
                    .init(color: Palette.background, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }

        /// Radial violet bloom used behind hero / welcome content.
        public static var heroBloom: RadialGradient {
            RadialGradient(
                colors: [Palette.accent.opacity(0.22), Palette.background],
                center: .center,
                startRadius: 0,
                endRadius: 640
            )
        }
    }

    // MARK: - Materials

    /// Translucent materials for the tvOS 26 / visionOS look — cards and chrome
    /// read as frosted glass over the cinematic background rather than flat
    /// opaque rectangles.
    public enum Materials {
        public static let card: Material = .ultraThinMaterial
        public static let chrome: Material = .regularMaterial
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

// MARK: - Color(hex:)

public extension Color {
    /// Build a `Color` from a 24-bit RGB hex literal, e.g. `Color(hex: 0x8B5CF6)`.
    /// Brand tokens are authored as hex to match the design spec exactly.
    init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}
