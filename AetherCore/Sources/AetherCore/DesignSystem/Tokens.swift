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
        /// Aether Gold — the warm cinematic accent extracted from the app icon's
        /// neon "A" mark. Pairs with violet on hero CTAs and the welcome /
        /// onboarding bloom. **Secondary accent only** — never replaces violet
        /// for selection, focus, or interactive primary actions.
        public static let accentGold = Color(hex: 0xF5B524)
        /// Slightly warmer amber sibling of `accentGold` — used for soft glows
        /// and the bottom anchor of `cinematic` gradients.
        public static let accentAmber = Color(hex: 0xF59E0B)

        // Surfaces — adaptive. Dark side keeps the OLED-friendly near-black
        // zinc tones the app shipped on for 0.3.x; light side mirrors the
        // tints Apple uses in the System / Music / TV apps under a light
        // appearance (near-white base, white cards, subtle elevated stripe).
        public static let background = Color(
            light: Color(hex: 0xF6F6F6),
            dark: Color(hex: 0x09090B)
        )
        public static let surface = Color(
            light: Color(hex: 0xFFFFFF),
            dark: Color(hex: 0x18181B)
        )
        public static let surfaceElevated = Color(
            light: Color(hex: 0xFAFAFA),
            dark: Color(hex: 0x27272A)
        )
        /// Hairline divider colour — uses the standard "ink at 10 %" on
        /// dark surfaces and a soft zinc stroke on light. Resolved by the
        /// trait collection, so cards keep their outline in both modes.
        public static let separator = Color(
            light: Color.black.opacity(0.10),
            dark: Color.white.opacity(0.10)
        )

        // Text — adaptive. Dark mode keeps `#FAFAFA / #A1A1AA / #71717A`
        // (the original zinc ramp). Light flips primary to near-black,
        // pulls secondary closer to mid-zinc for legibility on a white
        // surface, and reuses zinc-500 for tertiary (works in both).
        public static let textPrimary = Color(
            light: Color(hex: 0x0A0A0A),
            dark: Color(hex: 0xFAFAFA)
        )
        public static let textSecondary = Color(
            light: Color(hex: 0x52525B),
            dark: Color(hex: 0xA1A1AA)
        )
        public static let textTertiary = Color(
            light: Color(hex: 0x71717A),
            dark: Color(hex: 0x71717A)
        )

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

        /// Whole-screen atmosphere — two faint cosmic blooms (cool aurora
        /// upper-left, warm violet upper-right) over the adaptive
        /// `Palette.background`. On the dark side the blooms sit at
        /// 3–5 % opacity and read like distant nebula light; on the light
        /// side they're swapped for the same accents at half the opacity
        /// (so the screen still has subtle structure on white) — strong
        /// brand tints on a white background look like marketing
        /// material, so the light variant pulls way back. Inspired by
        /// Apple TV+, Disney+, and visionOS surfaces.
        public static var background: some View {
            ZStack {
                Palette.background
                RadialGradient(
                    colors: [
                        Color(
                            light: Palette.accentAurora.opacity(0.025),
                            dark: Palette.accentAurora.opacity(0.05)
                        ),
                        Color.clear
                    ],
                    center: UnitPoint(x: 0.15, y: 0.10),
                    startRadius: 0,
                    endRadius: 520
                )
                RadialGradient(
                    colors: [
                        Color(
                            light: Palette.accent.opacity(0.02),
                            dark: Palette.accent.opacity(0.04)
                        ),
                        Color.clear
                    ],
                    center: UnitPoint(x: 0.88, y: 0.18),
                    startRadius: 0,
                    endRadius: 600
                )
            }
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

        /// Violet → gold sweep for cinematic accents (the welcome glyph, the
        /// Aether wordmark on hero headers). Echoes the neon "A" on the app
        /// icon, where the violet halo gives way to the warm gold letterform.
        /// Use sparingly — once per screen at most.
        public static var cinematic: LinearGradient {
            LinearGradient(
                colors: [Palette.accentAurora, Palette.accent, Palette.accentGold],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
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

    /// Builds a colour that automatically resolves to one of two values
    /// based on the host trait collection's `userInterfaceStyle`. The
    /// foundation for the Appearance picker's System / Dark / Light
    /// triplet — every Palette surface / text token resolves through
    /// this so the UI tracks the system (or the user's explicit
    /// override via `.preferredColorScheme(_:)`).
    ///
    /// Uses `UIColor(dynamicProvider:)` under the hood, which Apple's
    /// SwiftUI bridges to a "resolve on read" `Color` — same machinery
    /// the system uses for `Color.systemBackground` and friends, so
    /// the value reacts to live trait changes without the view having
    /// to re-create it. Available on every platform Aether ships to
    /// (iOS / iPadOS / tvOS / visionOS).
    init(light: Color, dark: Color) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
        #else
        self = dark
        #endif
    }
}
