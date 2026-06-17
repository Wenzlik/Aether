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
    /// Community rating (≈0–10). When set and > 0, a compact number badge sits in
    /// the artwork's top-leading corner (#351) — just the figure, no label, so it
    /// barely takes space. `nil`/0 ⇒ no badge.
    public let rating: Double?
    /// How many lines the title may wrap to before truncating. Season cards
    /// pass `2` so longer "S2 · Asylum" labels stay legible instead of clipping
    /// to "Seaso…" (#263); most cards keep the single-line default.
    public let titleLineLimit: Int
    /// When set, a small Netflix badge (the TMDb-served logo) sits in the
    /// artwork's top-trailing corner — the "also on Netflix" signal (#360).
    public let netflixLogoURL: URL?
    /// Watched dimming intensity + label toggle, from the user's preference (#280).
    @Environment(\.watchedDisplay) private var watchedDisplay

    public init(
        title: String,
        subtitle: String? = nil,
        posterURL: URL? = nil,
        aspectRatio: CGFloat = 2.0 / 3.0,
        progress: Double? = nil,
        isWatched: Bool = false,
        rating: Double? = nil,
        titleLineLimit: Int = 1,
        netflixLogoURL: URL? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.posterURL = posterURL
        self.aspectRatio = aspectRatio
        self.progress = progress
        self.isWatched = isWatched
        self.rating = rating
        self.titleLineLimit = titleLineLimit
        self.netflixLogoURL = netflixLogoURL
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
            artwork
                .overlay(alignment: .bottom) { progressBar }
                .overlay(alignment: .topLeading) { ratingBadge }
                .overlay(alignment: .topTrailing) { netflixBadge }
                .clipShape(RoundedRectangle(cornerRadius: platformCornerRadius, style: .continuous))
                // Premium focus: lift + soft blue glow, no border (Apple TV+ feel).
                // Cards earn the larger lift.
                .premiumFocus(scale: 1.06)

            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xxs) {
                Text(title)
                    .font(AetherDesign.Typography.cardTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                    .lineLimit(titleLineLimit)
                    .minimumScaleFactor(0.82)
                    // Reserve the height of the maximum line count so all poster
                    // cards in a LazyVGrid row have the same total height and
                    // artwork tops align across columns.
                    .frame(minHeight: titleLineLimit > 1 ? 40 : 0, alignment: .topLeading)

                if let subtitle {
                    Text(subtitle)
                        .font(AetherDesign.Typography.caption)
                        .foregroundStyle(AetherDesign.Palette.textTertiary)
                        .lineLimit(1)
                }
            }
        }
    }

    /// Watched artwork wears the shared treatment (#280): dimming + a centered
    /// "WATCHED" wordmark + the gold corner ribbon. Unwatched renders at full
    /// saturation. See `watchedArtwork(_:display:compact:)`.
    private var artwork: some View {
        CachedAsyncImage(url: posterURL, aspectRatio: aspectRatio)
            .watchedArtwork(isWatched, display: watchedDisplay)
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

    /// A minimal community-rating chip (#351): just the score (one decimal) on a
    /// frosted capsule in the top-leading corner — deliberately tiny so it doesn't
    /// compete with the artwork. Hidden when there's no rating.
    @ViewBuilder
    private var ratingBadge: some View {
        if let rating, rating > 0 {
            Text(String(format: "%.1f", rating))
                .font(.system(size: ratingFontSize, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay { Capsule().stroke(.white.opacity(0.15), lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                .padding(AetherDesign.Spacing.xs)
        }
    }

    private var ratingFontSize: CGFloat {
        #if os(tvOS) || os(visionOS)
        return 15
        #else
        return 11
        #endif
    }

    /// "Also on Netflix" badge (#360): the TMDb-served provider logo in the
    /// artwork's top-trailing corner — license-clean (TMDb/JustWatch). Small and
    /// rounded so it reads as a provider chip, not a UI control. Hidden unless a
    /// logo URL was supplied.
    @ViewBuilder
    private var netflixBadge: some View {
        if let netflixLogoURL {
            CachedAsyncImage(url: netflixLogoURL, aspectRatio: 1)
                .frame(width: netflixBadgeSize, height: netflixBadgeSize)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(.white.opacity(0.15), lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                .padding(AetherDesign.Spacing.xs)
                .accessibilityLabel(Text("On Netflix"))
        }
    }

    private var netflixBadgeSize: CGFloat {
        #if os(tvOS) || os(visionOS)
        return 28
        #else
        return 20
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

public extension View {
    /// The shared **watched** artwork treatment (#280): dimming + a centered
    /// "WATCHED" wordmark + the gold corner ribbon — so poster cards and
    /// episode-row stills read identically. Apply to the artwork BEFORE
    /// clipping; the caller clips to its own corner radius. `compact` shrinks
    /// the wordmark + ribbon for small stills (episode list rows).
    func watchedArtwork(_ isWatched: Bool, display: WatchedDisplayConfig, compact: Bool = false) -> some View {
        modifier(WatchedArtworkTreatment(isWatched: isWatched, display: display, compact: compact))
    }
}

struct WatchedArtworkTreatment: ViewModifier {
    let isWatched: Bool
    let display: WatchedDisplayConfig
    let compact: Bool

    func body(content: Content) -> some View {
        content
            .saturation(isWatched ? display.dimming.saturation : 1)
            .overlay {
                if isWatched { Color.black.opacity(display.dimming.blackOpacity) }
            }
            .overlay(alignment: .center) {
                if isWatched, display.showLabel {
                    // Just the wordmark — bold white + a shadow for legibility,
                    // no box (#280 follow-up: "fakt jen text").
                    Text("WATCHED")
                        .font(.system(size: tagFontSize, weight: .heavy))
                        .tracking(2)
                        // Translucent so it reads as an overlay, not a hard
                        // label; opacity is user-tunable in Settings (#280). The
                        // shadow keeps it legible over any poster.
                        .foregroundStyle(.white.opacity(display.labelOpacity))
                        .shadow(color: .black.opacity(0.75), radius: 4, y: 1)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, AetherDesign.Spacing.xs)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isWatched { cornerMarker }
            }
    }

    private var tagFontSize: CGFloat {
        if compact { return 13 }
        #if os(tvOS) || os(visionOS)
        return 24
        #else
        return 15
        #endif
    }

    private var markerSize: CGFloat {
        if compact { return 28 }
        #if os(tvOS) || os(visionOS)
        return 56
        #else
        return 40
        #endif
    }

    @ViewBuilder
    private var cornerMarker: some View {
        let s = markerSize
        TopTrailingTriangle()
            .fill(AetherDesign.Palette.accentGold)
            .frame(width: s, height: s)
            .overlay(alignment: .topTrailing) {
                Image(systemName: "checkmark")
                    .font(.system(size: s * 0.32, weight: .heavy))
                    .foregroundStyle(.black)
                    .padding(.top, s * 0.12)
                    .padding(.trailing, s * 0.12)
            }
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
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
        rating: Double? = nil,
        titleLineLimit: Int = 2,
        netflixLogoURL: URL? = nil
    ) -> AetherCard {
        AetherCard(title: title, posterURL: posterURL, aspectRatio: 2.0 / 3.0, progress: progress, isWatched: isWatched, rating: rating, titleLineLimit: titleLineLimit, netflixLogoURL: netflixLogoURL)
    }

    /// 16:9 hero card — used for the featured rail and continue-watching, where
    /// the backdrop matters more than the poster. `progress` draws the frosted
    /// Continue-Watching strip along the lower edge; `rating` adds the compact
    /// community-rating badge — both are how the Discover hero carousel (#381)
    /// surfaces "you're 40% in" and "8.4" on a featured slide. `aspectRatio`
    /// defaults to 16:9; the Discover hero passes a wider cinematic ratio on
    /// iPad / visionOS so the banner can fill the full content width without
    /// becoming absurdly tall (the backdrop fills + crops to the ratio).
    public static func hero(
        title: String,
        subtitle: String? = nil,
        posterURL: URL?,
        progress: Double? = nil,
        rating: Double? = nil,
        aspectRatio: CGFloat = 16.0 / 9.0
    ) -> AetherCard {
        AetherCard(title: title, subtitle: subtitle, posterURL: posterURL, aspectRatio: aspectRatio, progress: progress, rating: rating)
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
