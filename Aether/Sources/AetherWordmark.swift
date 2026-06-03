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
    /// Optional supporting line displayed under "Aether" on the right side of
    /// the mark. When set, the layout becomes a landing-page-style brand block:
    ///
    /// ```
    /// [logo]  Aether
    ///         tagline
    /// ```
    ///
    /// When `nil` the wordmark stays single-line next to the mark — the
    /// original inline pattern used on sign-in / discovery screens.
    public let tagline: String?

    public init(_ variant: Variant = .medium, tagline: String? = nil) {
        self.variant = variant
        self.tagline = tagline
    }

    public var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            brandMark
            if let tagline {
                VStack(alignment: .leading, spacing: AetherDesign.Spacing.xxs) {
                    wordmarkText
                    Text(tagline)
                        .font(taglineFont)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                wordmarkText
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tagline.map { "Aether. \($0)" } ?? "Aether")
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

    /// Mark size, in points. Tuned so the wordmark stays the primary focal
    /// point (the type carries identity; the mark anchors it) — the mark is
    /// roughly 1.4× the type size at large, narrowing to 1.2× at small so
    /// the inline variant doesn't feel logo-led.
    private var markSize: CGFloat {
        switch variant {
        case .small:  return 22
        case .medium: return 36
        case .large:  return 56
        }
    }

    /// Type size. The wordmark width (5 characters of display-weight text)
    /// already exceeds the mark width at every variant, so "Aether" reads as
    /// the focal point even when the mark is slightly taller.
    private var typeSize: CGFloat {
        switch variant {
        case .small:  return 18
        case .medium: return 26
        case .large:  return 40
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

    /// Tagline typography — supporting role, smaller than the wordmark so the
    /// brand block reads `Aether` first, supporting copy second.
    private var taglineFont: Font {
        switch variant {
        case .small:  return AetherDesign.Typography.caption
        case .medium: return AetherDesign.Typography.metadata
        case .large:  return AetherDesign.Typography.body
        }
    }
}

// MARK: - Previews

#Preview("Wordmark variants") {
    VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
        AetherWordmark(.large, tagline: "Your media, beautifully organized.")
        AetherWordmark(.medium, tagline: "Settings")
        AetherWordmark(.small)
        AetherWordmark(.large)
    }
    .padding(AetherDesign.Spacing.xxl)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AetherDesign.Palette.background.ignoresSafeArea())
    .preferredColorScheme(.dark)
}
