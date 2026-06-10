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
    /// Shows a "watched" checkmark badge over the artwork when `true`.
    public let isWatched: Bool

    public init(
        title: String,
        subtitle: String? = nil,
        posterURL: URL? = nil,
        aspectRatio: CGFloat = 2.0 / 3.0,
        progress: Double? = nil,
        isWatched: Bool = false
    ) {
        self.title = title
        self.subtitle = subtitle
        self.posterURL = posterURL
        self.aspectRatio = aspectRatio
        self.progress = progress
        self.isWatched = isWatched
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
            artwork
                .overlay(alignment: .bottom) { progressBar }
                .overlay(alignment: .topTrailing) { watchedCornerMarker }
                .clipShape(RoundedRectangle(cornerRadius: platformCornerRadius, style: .continuous))
                // Premium focus: lift + soft blue glow, no border (Apple TV+ feel).
                // Cards earn the larger lift.
                .premiumFocus(scale: 1.06)

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

    /// Watched artwork is **dimmed + desaturated** so a finished title reads as
    /// "done" at a glance across a large library (#246) — still attractive, just
    /// visibly muted. Unwatched artwork renders at full saturation.
    private var artwork: some View {
        CachedAsyncImage(url: posterURL, aspectRatio: aspectRatio)
            .saturation(isWatched ? 0.45 : 1)
            .overlay {
                if isWatched { Color.black.opacity(0.28) }
            }
    }

    /// "Watched" marker — a filled triangle folded into the top-trailing corner
    /// with a bold checkmark, far more legible from couch distance than a small
    /// icon (#246). Larger on the 10-foot / spatial UI.
    @ViewBuilder
    private var watchedCornerMarker: some View {
        if isWatched {
            let s = watchedMarkerSize
            TopTrailingTriangle()
                .fill(AetherDesign.Palette.accent)
                .frame(width: s, height: s)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "checkmark")
                        .font(.system(size: s * 0.32, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.top, s * 0.12)
                        .padding(.trailing, s * 0.12)
                }
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        }
    }

    private var watchedMarkerSize: CGFloat {
        #if os(tvOS) || os(visionOS)
        return 56
        #else
        return 40
        #endif
    }

    /// Apple-TV-style progress: a frosted strip across the artwork's lower edge
    /// (so it reads as part of the poster, not a detached line) with a 2pt
    /// gradient fill in the brand blue. Clipped by the card's rounded corners
    /// (the overlays are composited before the parent `clipShape`).
    @ViewBuilder
    private var progressBar: some View {
        if let progress {
            let clamped = CGFloat(max(0, min(progress, 1)))
            ZStack(alignment: .bottom) {
                Rectangle().fill(AetherDesign.Materials.card)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.white.opacity(0.18))
                        Rectangle()
                            .fill(AetherDesign.Gradients.progress)
                            .frame(width: geo.size.width * clamped)
                    }
                    .frame(height: 2)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .frame(height: progressStripHeight)
            .clipShape(
                UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8, style: .continuous)
            )
        }
    }

    /// Taller frosted strip on the 10-foot / spatial UI, slimmer on touch.
    private var progressStripHeight: CGFloat {
        #if os(tvOS) || os(visionOS)
        return 28
        #else
        return 22
        #endif
    }

    private var platformCornerRadius: CGFloat {
        #if os(tvOS)
        AetherDesign.Radius.cardTV
        #else
        AetherDesign.Radius.card
        #endif
    }
}

/// A right triangle filling the top-trailing corner of its frame (hypotenuse
/// from top-leading to bottom-trailing) — the "folded corner" watched ribbon.
private struct TopTrailingTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Factories

extension AetherCard {

    /// 2:3 poster card — the canonical library shape for movies and shows.
    public static func poster(
        title: String,
        posterURL: URL?,
        progress: Double? = nil,
        isWatched: Bool = false
    ) -> AetherCard {
        AetherCard(title: title, posterURL: posterURL, aspectRatio: 2.0 / 3.0, progress: progress, isWatched: isWatched)
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
            AetherCard.poster(title: "Watched Title", posterURL: nil, isWatched: true)
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
