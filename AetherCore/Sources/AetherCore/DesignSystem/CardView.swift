import SwiftUI

/// Placeholder poster/episode card. Components fill out in 0.1 Foundation.
public struct CardView: View {
    public let title: String
    public let aspectRatio: CGFloat

    public init(title: String, aspectRatio: CGFloat = 2.0 / 3.0) {
        self.title = title
        self.aspectRatio = aspectRatio
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
            RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                .fill(AetherDesign.Palette.surface)
                .aspectRatio(aspectRatio, contentMode: .fit)
            Text(title)
                .font(AetherDesign.Typography.cardTitle)
                .foregroundStyle(AetherDesign.Palette.textPrimary)
                .lineLimit(1)
        }
    }
}
