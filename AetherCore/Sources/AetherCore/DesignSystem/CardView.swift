import SwiftUI

/// Poster / episode card.
///
/// Renders artwork (via `CachedAsyncImage`) in the correct aspect ratio with the
/// title beneath it in `cardTitle` weight. On tvOS the card lifts softly when
/// focused — no type reflow, no 3D parallax.
///
/// Aspect ratios commonly used:
/// - Posters: `2.0 / 3.0`
/// - Episodes / stills: `16.0 / 9.0`
/// - Music: `1.0`
public struct CardView: View {
    public let title: String
    public let posterURL: URL?
    public let aspectRatio: CGFloat
    public let progress: Double?

    @Environment(\.isFocused) private var isFocused

    public init(
        title: String,
        posterURL: URL? = nil,
        aspectRatio: CGFloat = 2.0 / 3.0,
        progress: Double? = nil
    ) {
        self.title = title
        self.posterURL = posterURL
        self.aspectRatio = aspectRatio
        self.progress = progress
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
            artwork
                .clipShape(RoundedRectangle(cornerRadius: platformCornerRadius, style: .continuous))
                .overlay(alignment: .bottom) { progressBar }
                .shadow(color: .black.opacity(isFocused ? 0.45 : 0.0),
                        radius: isFocused ? 18 : 0,
                        y: isFocused ? 12 : 0)
                .scaleEffect(isFocused ? 1.06 : 1.0)
                .animation(AetherDesign.Motion.focus, value: isFocused)

            Text(title)
                .font(AetherDesign.Typography.cardTitle)
                .foregroundStyle(AetherDesign.Palette.textPrimary)
                .lineLimit(1)
        }
    }

    private var artwork: some View {
        CachedAsyncImage(url: posterURL, aspectRatio: aspectRatio)
    }

    @ViewBuilder
    private var progressBar: some View {
        if let progress {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(.black.opacity(0.45))
                    Rectangle()
                        .fill(AetherDesign.Palette.accent)
                        .frame(width: geo.size.width * max(0, min(progress, 1)))
                }
            }
            .frame(height: 3)
        }
    }

    private var platformCornerRadius: CGFloat {
        #if os(tvOS)
        AetherDesign.Radius.cardTV
        #else
        AetherDesign.Radius.card
        #endif
    }
}

#if DEBUG
struct CardView_Previews: PreviewProvider {
    static var previews: some View {
        HStack(alignment: .top, spacing: AetherDesign.Spacing.l) {
            CardView(title: "Sample Title", posterURL: nil)
                .frame(width: 160)
            CardView(
                title: "S1E3 — A Long Episode Name That Might Truncate",
                posterURL: nil,
                aspectRatio: 16.0 / 9.0,
                progress: 0.42
            )
            .frame(width: 280)
        }
        .padding(AetherDesign.Spacing.l)
        .background(AetherDesign.Palette.background)
        .previewLayout(.sizeThatFits)
    }
}
#endif
