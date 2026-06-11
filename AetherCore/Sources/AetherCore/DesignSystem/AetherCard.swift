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
    /// How many lines the title may wrap to before truncating. Season cards
    /// pass `2` so longer "S2 · Asylum" labels stay legible instead of clipping
    /// to "Seaso…" (#263); most cards keep the single-line default.
    public let titleLineLimit: Int
    /// Watched dimming intensity + label toggle, from the user's preference (#280).
    @Environment(\.watchedDisplay) private var watchedDisplay

    public init(
        title: String,
        subtitle: String? = nil,
        posterURL: URL? = nil,
        aspectRatio: CGFloat = 2.0 / 3.0,
        progress: Double? = nil,
        isWatched: Bool = false,
        titleLineLimit: Int = 1
    ) {
        self.title = title
        self.subtitle = subtitle
        self.posterURL = posterURL
        self.aspectRatio = aspectRatio
        self.progress = progress
        self.isWatched = isWatched
        self.titleLineLimit = titleLineLimit
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
                    .lineLimit(titleLineLimit)

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
    /// visibly muted — plus an unmissable centered "WATCHED" tag. Unwatched
    /// artwork renders at full saturation.
    private var artwork: some View {
        CachedAsyncImage(url: posterURL, aspectRatio: aspectRatio)
            .saturation(isWatched ? watchedDisplay.dimming.saturation : 1)
            .overlay {
                if isWatched { Color.black.opacity(watchedDisplay.dimming.blackOpacity) }
            }
            .overlay {
                if isWatched, watchedDisplay.showLabel { watchedTag }
            }
    }

    /// Centered "WATCHED" capsule over finished artwork — bold + sized to read
    /// from couch distance even when the gold corner marker is scrolled by (#280).
    private var watchedTag: some View {
        Text("WATCHED")
            .font(.system(size: watchedTagFontSize, weight: .heavy))
            .tracking(2)
            .foregroundStyle(Color.white)
            .padding(.horizontal, AetherDesign.Spacing.m)
            .padding(.vertical, AetherDesign.Spacing.xs)
            .background(Color.black.opacity(0.6), in: Capsule())
            .overlay(
                Capsule().strokeBorder(AetherDesign.Palette.accentGold, lineWidth: 1.5)
            )
            .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
            .padding(.horizontal, AetherDesign.Spacing.xs)
    }

    private var watchedTagFontSize: CGFloat {
        #if os(tvOS) || os(visionOS)
        return 24
        #else
        return 15
        #endif
    }

    /// "Watched" marker — a filled triangle folded into the top-trailing corner
    /// with a bold checkmark, far more legible from couch distance than a small
    /// icon (#246). Larger on the 10-foot / spatial UI.
    @ViewBuilder
    private var watchedCornerMarker: some View {
        if isWatched {
            let s = watchedMarkerSize
            TopTrailingTriangle()
                // Gold corner ribbon: a warm, high-contrast "watched" signal
                // that stands apart from the blue accent / focus glow (#246).
                .fill(AetherDesign.Palette.accentGold)
                .frame(width: s, height: s)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "checkmark")
                        .font(.system(size: s * 0.32, weight: .heavy))
                        // Dark check — white washes out on bright gold.
                        .foregroundStyle(.black)
                        .padding(.top, s * 0.12)
                        .padding(.trailing, s * 0.12)
                }
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
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
    /// (so it reads as part of the poster, not a detached line) holding an inset,
    /// rounded **progress bar** in the brand blue. The bar is several points tall
    /// and inset from the edges so it reads from couch distance — a hairline at
    /// the very bottom was nearly invisible on the 10-foot UI.
    @ViewBuilder
    private var progressBar: some View {
        if let progress {
            let clamped = CGFloat(max(0, min(progress, 1)))
            ZStack(alignment: .bottom) {
                Rectangle().fill(AetherDesign.Materials.card)
                GeometryReader { geo in
                    let trackWidth = geo.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.28))
                        Capsule()
                            .fill(AetherDesign.Gradients.progress)
                            // Never thinner than its own height, so even a few
                            // percent shows a clear rounded nub rather than nothing.
                            .frame(width: max(progressBarThickness, trackWidth * clamped))
                    }
                    .frame(height: progressBarThickness)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .padding(.horizontal, progressBarInset)
                .padding(.bottom, progressBarInset)
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

    /// Height of the actual progress bar inside the frosted strip — bold enough
    /// to read across a room on the 10-foot UI, slimmer on touch.
    private var progressBarThickness: CGFloat {
        #if os(tvOS) || os(visionOS)
        return 7
        #else
        return 5
        #endif
    }

    /// Inset of the bar from the strip's side and bottom edges, so it reads as a
    /// rounded pill floating in the strip rather than glued to the corner.
    private var progressBarInset: CGFloat {
        #if os(tvOS) || os(visionOS)
        return 8
        #else
        return 6
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
        isWatched: Bool = false,
        titleLineLimit: Int = 1
    ) -> AetherCard {
        AetherCard(title: title, posterURL: posterURL, aspectRatio: 2.0 / 3.0, progress: progress, isWatched: isWatched, titleLineLimit: titleLineLimit)
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
