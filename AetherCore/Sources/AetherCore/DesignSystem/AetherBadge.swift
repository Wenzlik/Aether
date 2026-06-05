import SwiftUI

/// A compact capsule chip for a single technical fact — `4K`, `HDR`,
/// `Dolby Vision`, `HEVC`, `AC3 5.1`. Used as a row of badges under a title's
/// metadata so quality reads at a glance (Apple TV / Infuse style), instead of
/// hiding in a settings table.
///
/// Frosted-glass background so it stays legible over a backdrop image. Pull the
/// label text from `MediaInfo`; this view is display-only.
public struct AetherBadge: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.system(.caption2, design: .default, weight: .semibold))
            .foregroundStyle(AetherDesign.Palette.textPrimary)
            .padding(.horizontal, AetherDesign.Spacing.xs)
            .padding(.vertical, AetherDesign.Spacing.xxs)
            .background(AetherDesign.Materials.card, in: Capsule())
            .overlay(
                Capsule().strokeBorder(AetherDesign.Palette.separator, lineWidth: 1)
            )
    }
}
