import SwiftUI
import AetherCore

/// Aether's brand mark composed of the app-icon glyph and the "Aether"
/// wordmark, designed to read as a single recognisable identity wherever it
/// appears in the app.
///
/// Lives in the **app target** (not `AetherCore`) because it depends on the
/// `AetherBrandMark` asset that's shipped with the app's xcassets — the
/// AetherCore package is intentionally brand-asset-free so it can be lifted
/// into other personal-cinema projects without dragging this identity along.
///
/// Visual rules (kept deliberately Apple-restrained):
/// - The wordmark is **SF Pro Display, Semibold**, white. Only the leading
///   "A" wears the violet→aurora gradient — every other letter stays white,
///   so the mark reads as text first, brand accent second.
/// - Letter spacing is increased slightly via `.kerning(_:)`. The kerning
///   value scales with the variant so the wordmark stays balanced at any
///   size (more kerning on the large display variant, less on small).
/// - The brand icon is rendered with the iOS-app-icon corner radius
///   (~22% of the side length, `style: .continuous`) so it reads as the
///   same mark users see on their home screen, just inline.
/// - **No outer glow, no bevel, no outline.** visionOS surfaces and dark
///   detail screens already provide their own depth; an extra glow would
///   read as garish next to system materials. The icon's own internal glow
///   (baked into the artwork) is the only luminance in the component.
///
/// Use it at the top of hero / welcome / onboarding surfaces, not in every
/// nav bar — over-application would dilute the mark.
public struct AetherWordmark: View {
    public enum Variant: Sendable {
        /// Inline / small-header use — about as tall as a callout-sized line of
        /// body text. Suitable for source-connection screens and the Settings
        /// `About` row.
        case small
        /// The default — Settings and Library hero headers where the wordmark
        /// shares space with secondary metadata (version, tagline).
        case medium
        /// Hero / welcome — the dominant brand statement on Welcome and other
        /// "first impression" surfaces.
        case large
    }

    public let variant: Variant

    public init(_ variant: Variant = .medium) {
        self.variant = variant
    }

    public var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            brandMark
            wordmarkText
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Aether")
    }

    // MARK: - Mark

    private var brandMark: some View {
        Image("AetherBrandMark")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: markSize, height: markSize)
            .clipShape(RoundedRectangle(cornerRadius: markSize * 0.22, style: .continuous))
    }

    // MARK: - Wordmark

    /// "Aether" with a single-letter gradient on "A" and the rest in white.
    /// Uses iOS 26's `Text` string interpolation (the `Text + Text` `+`
    /// operator was deprecated in iOS 26) — embedding a styled `Text` via
    /// `\(...)` keeps per-segment foregroundStyle while the outer modifiers
    /// (font, kerning) flow through both halves so the letterforms stay
    /// perfectly tracked.
    private var wordmarkText: some View {
        let gradient = LinearGradient(
            colors: [
                AetherDesign.Palette.accent,
                AetherDesign.Palette.accentAurora
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        return Text("\(Text("A").foregroundStyle(gradient))ether")
            .foregroundStyle(AetherDesign.Palette.textPrimary)
            .font(.system(size: typeSize, weight: .semibold, design: .default))
            .kerning(kerning)
            .lineLimit(1)
            .fixedSize()
    }

    // MARK: - Variant metrics

    /// Approx 1:1 ratio with the wordmark cap height so the mark sits visually
    /// flush against the type without dominating it.
    private var markSize: CGFloat {
        switch variant {
        case .small:  return 26
        case .medium: return 38
        case .large:  return 64
        }
    }

    /// Type size scales the same direction as the mark, weighted so the
    /// wordmark always feels lighter than the mark (the type carries identity,
    /// the mark anchors it).
    private var typeSize: CGFloat {
        switch variant {
        case .small:  return 18
        case .medium: return 26
        case .large:  return 44
        }
    }

    /// Increased letter spacing scales with the type size. Apple's display
    /// fonts already tighten optical kerning automatically; we add a touch
    /// more so the wordmark reads as a "display" mark, not running text.
    private var kerning: CGFloat {
        switch variant {
        case .small:  return 0.4
        case .medium: return 0.6
        case .large:  return 1.0
        }
    }

    /// Gap between mark and wordmark. Tuned visually so the mark feels paired
    /// with the wordmark, not floating ahead of it.
    private var spacing: CGFloat {
        switch variant {
        case .small:  return AetherDesign.Spacing.xs
        case .medium: return AetherDesign.Spacing.s
        case .large:  return AetherDesign.Spacing.m
        }
    }
}

// MARK: - Previews

#Preview("Wordmark variants") {
    VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
        AetherWordmark(.large)
        AetherWordmark(.medium)
        AetherWordmark(.small)
    }
    .padding(AetherDesign.Spacing.xxl)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AetherDesign.Palette.background.ignoresSafeArea())
    .preferredColorScheme(.dark)
}
