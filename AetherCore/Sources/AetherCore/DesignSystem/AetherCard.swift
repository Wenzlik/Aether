import SwiftUI

/// Cinematic card used for posters, episode stills, and hero items.
///
/// Renders artwork (via `CachedAsyncImage`) in the requested aspect ratio with
/// the title beneath it in `cardTitle` weight. On tvOS the card lifts softly
/// when focused — no type reflow, no 3D parallax.
///
/// Prefer the static factories (`.poster`, `.hero`, `.episode`) over the raw
/// initializer; they document the three shapes the rest of the app already
/// uses and keep call sites honest about which one they want.
public struct AetherCard: View {
    public let title: String
    public let subtitle: String?
    public let posterURL: URL?
    public let aspectRatio: CGFloat
    public let progress: Double?

    @Environment(\.isFocused) private var isFocused

    public init(
        title: String,
        subtitle: String? = nil,
        posterURL: URL? = nil,
        aspectRatio: CGFloat = 2.0 / 3.0,
        progress: Double? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.posterURL = posterURL
        self.aspectRatio = aspectRatio
        self.progress = progress
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
            let shape = RoundedRectangle(cornerRadius: platformCornerRadius, style: .continuous)

            artwork
                .clipShape(shape)
                .overlay(alignment: .bottom) { progressBar }
                .overlay {
                    shape.stroke(AetherDesign.Palette.separator, lineWidth: 1)
                }
                .shadow(color: .black.opacity(isFocused ? 0.45 : 0.0),
                        radius: isFocused ? 18 : 0,
                        y: isFocused ? 12 : 0)
                .scaleEffect(isFocused ? 1.06 : 1.0)
                .animation(AetherDesign.Motion.focus, value: isFocused)

            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xxs) {
                Text(title)
                    .font(AetherDesign.Typography.cardTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                    .lineLimit(1)

                if let subtitle {
                    Text(subtitle)
                        .font(AetherDesign.Typography.caption)
                        .foregroundStyle(AetherDesign.Palette.textTertiary)
                        .lineLimit(1)
                }
            }
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

// MARK: - Factories

extension AetherCard {

    /// 2:3 poster card — the canonical library shape for movies and shows.
    public static func poster(
        title: String,
        posterURL: URL?,
        progress: Double? = nil
    ) -> AetherCard {
        AetherCard(title: title, posterURL: posterURL, aspectRatio: 2.0 / 3.0, progress: progress)
    }

    /// 16:9 hero card — used for the featured rail and continue-watching, where
    /// the backdrop matters more than the poster.
    public static func hero(
        title: String,
        subtitle: String? = nil,
        posterURL: URL?
    ) -> AetherCard {
        AetherCard(title: title, subtitle: subtitle, posterURL: posterURL, aspectRatio: 16.0 / 9.0)
    }

    /// 16:9 episode still — same shape as hero, but conventionally smaller and
    /// often carries a progress overlay.
    public static func episode(
        title: String,
        thumbURL: URL?,
        progress: Double? = nil
    ) -> AetherCard {
        AetherCard(title: title, posterURL: thumbURL, aspectRatio: 16.0 / 9.0, progress: progress)
    }
}

#if DEBUG
struct AetherCard_Previews: PreviewProvider {
    static var previews: some View {
        HStack(alignment: .top, spacing: AetherDesign.Spacing.l) {
            AetherCard.poster(title: "Sample Title", posterURL: nil)
                .frame(width: 160)
            AetherCard.episode(
                title: "S1E3 — A Long Episode Name That Might Truncate",
                thumbURL: nil,
                progress: 0.42
            )
            .frame(width: 280)
            AetherCard.hero(title: "Featured", subtitle: "Picked for you", posterURL: nil)
                .frame(width: 320)
        }
        .padding(AetherDesign.Spacing.l)
        .background(AetherDesign.Palette.background)
        .previewLayout(.sizeThatFits)
    }
}
#endif
