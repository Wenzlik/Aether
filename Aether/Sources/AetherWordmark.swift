import SwiftUI
import AetherCore

/// Aether's brand mark — the symbol-plus-wordmark lockup that identifies the
/// app inside its own UI (welcome / sign-in / hero headers).
///
/// Backed by a single artwork file (`AetherBrandMark` in the app's xcassets)
/// that already bakes the glyph + the "AETHER" wordmark + the gold→blue
/// gradient + the under-mark glow line into one image. Previously this view
/// composed the icon and the wordmark in SwiftUI (`Image` + per-letter
/// `Text` with a gradient on "A"); the artwork upgrade lets us render the
/// mark as a single, designer-controlled lockup instead of a code-built
/// approximation. The variant sizes below are tuned by *height*, not type
/// scale — the artwork's intrinsic aspect ratio (~3:2) carries width.
///
/// Use at the top of welcome / onboarding / sign-in surfaces. Don't repeat
/// in every nav bar; over-application dilutes the mark.
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
    /// Optional supporting line displayed beneath the lockup. The artwork
    /// is intentionally self-contained (icon + "AETHER" in one image), so a
    /// tagline now stacks **below** the mark instead of sitting next to the
    /// wordmark text — there is no separate wordmark to sit next to anymore.
    public let tagline: String?

    public init(_ variant: Variant = .medium, tagline: String? = nil) {
        self.variant = variant
        self.tagline = tagline
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
            logo
            if let tagline {
                Text(tagline)
                    .font(taglineFont)
                    .foregroundStyle(AetherDesign.Palette.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tagline.map { "Aether. \($0)" } ?? "Aether")
    }

    private var logo: some View {
        Image("AetherBrandMark")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(height: logoHeight)
    }

    /// Lockup height in points. Width follows the artwork's aspect ratio
    /// (~3:1 after the dark vertical padding was cropped out of the
    /// source PNG), so a `.large` mark renders ~180pt wide. Tuned so the
    /// embedded "AETHER" wordmark stays comfortably legible at each tier
    /// without dominating the surface horizontally — at 60pt tall × 180pt
    /// wide, the large variant occupies about half an iPhone's content
    /// width, leaving room for "Library" / "Settings" labels beside it.
    private var logoHeight: CGFloat {
        switch variant {
        case .small:  return 22
        case .medium: return 36
        case .large:  return 60
        }
    }

    /// Tagline typography. Caption at small, metadata at medium, body at
    /// large — keeps the supporting copy a step below the lockup's
    /// visual weight at every tier.
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
