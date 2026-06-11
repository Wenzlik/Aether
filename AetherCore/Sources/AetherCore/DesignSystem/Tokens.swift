import SwiftUI

/// Design tokens for Aether's visual language — a calm, cinematic "personal
/// cinema" look built on a premium **blue** brand (0.6.0 refresh, was violet)
/// over a layered near-black base. Numeric values + rationale live in
/// `docs/ux/DESIGN_PRINCIPLES.md` and `docs/next-steps/ux-refresh-060.md`.
/// Never hard-code a colour, gradient, font, spacing, radius, or duration in a
/// view — pull it from here.
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

    // MARK: - Layout

    /// Width cap for the compact nav-header search field (Home / Library). The
    /// field used to fill the row; the 0.6.x header refresh shrinks it and pins
    /// it to the trailing edge beside Reload, so the brand mark leads the row.
    /// Roughly the Reload button's footprint on the 10-foot UI, a touch tighter
    /// on phones.
    public static var headerSearchWidth: CGFloat {
        #if os(tvOS)
        return 360
        #else
        return 300
        #endif
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
    /// brand accent is **Aether Blue** — a premium, visionOS-aligned blue;
    /// surfaces are a layered near-black for an OLED-friendly cinematic base.
    /// (0.6.0 brand refresh — replaced the original violet; see
    /// `docs/next-steps/ux-refresh-060.md`.)
    public enum Palette {
        // Brand accents — premium blue primary, subtle purple secondary.
        /// Aether Blue — the **primary** accent (focus, selection, primary
        /// action, links, section accents). Re-pointed from violet in 0.6.0, so
        /// every existing `Palette.accent` call site reads premium blue.
        public static let accent = Color(hex: 0x6A8BFF)
        /// Brightened blue — focus glow, progress fill, hover/active, and the
        /// bright stop of the brand gradients.
        public static let accentBright = Color(hex: 0x5B7CFF)
        /// Darker indigo — the depth partner / dark stop of `aurora` & `progress`.
        public static let accentIndigo = Color(hex: 0x4C63E0)
        /// Subtle Purple — **secondary accent only** (muted / planned status,
        /// tertiary tints, the secondary background bloom). Never primary
        /// interactive state.
        public static let accentSecondary = Color(hex: 0x9B7EBF)
        /// Aether Gold — the warm accent from the app icon's neon "A" mark.
        /// **Brand-mark pairing only** (the `cinematic` gradient / wordmark) —
        /// never interactive.
        public static let accentGold = Color(hex: 0xF5B524)
        /// Slightly warmer amber sibling of `accentGold` — soft glows / warm
        /// anchor of the `cinematic` gradient only.
        public static let accentAmber = Color(hex: 0xF59E0B)

        // Surfaces — adaptive, layered dark base. Dark side is a three-stop
        // gradient (top #0B0D12 → mid #111827 → bottom #0A0A0F) for cinematic
        // depth instead of flat near-black; light side mirrors the tints Apple
        // uses in System / Music / TV under a light appearance.
        /// Top anchor of the layered background gradient.
        public static let background = Color(
            light: Color(hex: 0xF6F6F6),
            dark: Color(hex: 0x0B0D12)
        )
        /// Middle (charcoal-blue) depth stop of the background gradient.
        public static let backgroundMid = Color(
            light: Color(hex: 0xFFFFFF),
            dark: Color(hex: 0x111827)
        )
        /// Bottom (near-black) anchor of the background gradient.
        public static let backgroundBottom = Color(
            light: Color(hex: 0xF6F6F6),
            dark: Color(hex: 0x0A0A0F)
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
        /// Orange-red — distinct from brand gold (`accentGold`) so a status
        /// warning never reads as a brand accent.
        public static let warning = Color(hex: 0xF97316)
        public static let error = Color(hex: 0xEF4444)

        /// The colour of the soft focus glow (a shadow colour on focused cards /
        /// buttons / rows). The bright blue — the fill/border identity is
        /// `accent`, the glow is `accentBright`.
        public static let focusGlow = accentBright
    }

    /// Convenience alias so new code can read `AetherDesign.Colors.accent` per
    /// the brand-system naming, while existing call sites keep using `Palette`.
    public typealias Colors = Palette

    // MARK: - Gradients

    /// Brand gradients. Computed so they don't pin global state under strict
    /// concurrency, and cheap to build at the call site.
    public enum Gradients {
        /// Hero / featured wash and primary-button fill — indigo → bright blue.
        public static var aurora: LinearGradient {
            LinearGradient(
                colors: [Palette.accentIndigo, Palette.accentBright],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        /// Progress fill (Continue Watching bars, scrubbers) — indigo → bright blue.
        public static var progress: LinearGradient {
            LinearGradient(
                colors: [Palette.accentIndigo, Palette.accentBright],
                startPoint: .leading,
                endPoint: .trailing
            )
        }

        /// The layered base — top → mid → bottom, the cinematic-depth substrate
        /// the blooms sit on (replaces flat `Palette.background`).
        public static var backgroundBase: LinearGradient {
            LinearGradient(
                colors: [Palette.background, Palette.backgroundMid, Palette.backgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        /// Whole-screen atmosphere — the layered base plus two faint blooms
        /// (bright-blue upper-left, subtle-purple upper-right). On dark the
        /// blooms sit at 6–8 % for cinematic depth while staying subtle; on
        /// light they pull back to 3–4 % so a white screen still has structure
        /// without reading like marketing material. Apply via
        /// `.aetherScreenBackground()`. Inspired by Apple TV+ / visionOS.
        public static var background: some View {
            ZStack {
                backgroundBase
                RadialGradient(
                    colors: [
                        Color(
                            light: Palette.accentBright.opacity(0.04),
                            dark: Palette.accentBright.opacity(0.08)
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
                            light: Palette.accentSecondary.opacity(0.03),
                            dark: Palette.accentSecondary.opacity(0.06)
                        ),
                        Color.clear
                    ],
                    center: UnitPoint(x: 0.88, y: 0.18),
                    startRadius: 0,
                    endRadius: 600
                )
            }
        }

        /// Radial blue bloom used behind hero / welcome content.
        public static var heroBloom: RadialGradient {
            RadialGradient(
                colors: [Palette.accentBright.opacity(0.28), Palette.background],
                center: .center,
                startRadius: 0,
                endRadius: 640
            )
        }

        /// Blue → gold sweep for the brand mark (the welcome glyph, the Aether
        /// wordmark). Echoes the neon "A" on the app icon — the blue halo gives
        /// way to the warm gold letterform. Brand-mark only; once per screen.
        public static var cinematic: LinearGradient {
            LinearGradient(
                colors: [Palette.accentBright, Palette.accent, Palette.accentGold],
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
