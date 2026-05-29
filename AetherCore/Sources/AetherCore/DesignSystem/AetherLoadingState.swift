import SwiftUI

/// A calm loading state — skeleton rails, no spinners.
///
/// `AetherLoadingState.rails(count:)` matches the Home page rhythm (a title row
/// + a horizontal strip of poster placeholders) and uses `.redacted` so the
/// shape mirrors real content. `AetherLoadingState.inline()` is a thin
/// horizontal pulse for footer / hint use, where a full rail would be too much.
public struct AetherLoadingState: View {
    public enum Style: Sendable {
        case rails(count: Int)
        case inline
    }

    public let style: Style

    public init(_ style: Style = .rails(count: 2)) {
        self.style = style
    }

    public var body: some View {
        switch style {
        case let .rails(count):
            railsBody(count: count)
        case .inline:
            inlineBody
        }
    }

    // MARK: - Rails

    private func railsBody(count: Int) -> some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            ForEach(0..<max(1, count), id: \.self) { _ in
                Rectangle()
                    .fill(AetherDesign.Palette.surface)
                    .frame(height: 22)
                    .frame(maxWidth: 220, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(.horizontal, AetherDesign.Spacing.l)

                HStack(spacing: AetherDesign.Spacing.m) {
                    ForEach(0..<4, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                            .fill(AetherDesign.Palette.surface)
                            .frame(width: cardWidth, height: cardHeight)
                    }
                }
                .padding(.horizontal, AetherDesign.Spacing.l)
            }
        }
        .redacted(reason: .placeholder)
    }

    private var cardWidth: CGFloat {
        #if os(tvOS)
        300
        #else
        160
        #endif
    }

    private var cardHeight: CGFloat {
        cardWidth * (3.0 / 2.0)
    }

    // MARK: - Inline

    private var inlineBody: some View {
        Rectangle()
            .fill(AetherDesign.Palette.surface)
            .frame(height: 14)
            .frame(maxWidth: 220, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .redacted(reason: .placeholder)
    }
}

#if DEBUG
struct AetherLoadingState_Previews: PreviewProvider {
    static var previews: some View {
        AetherLoadingState(.rails(count: 2))
            .padding(.vertical, AetherDesign.Spacing.l)
            .background(AetherDesign.Palette.background)
            .previewLayout(.sizeThatFits)
    }
}
#endif
