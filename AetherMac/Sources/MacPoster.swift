import SwiftUI
import AetherCore

/// A library poster card. Watched titles get the **shared mobile treatment**
/// (#280): desaturation + a black wash + a centered "WATCHED" wordmark + the
/// gold corner ribbon — tuned by the user's Settings (`\.watchedDisplay`), not
/// just a tiny checkmark. Pure visual — call sites wrap it in a NavigationLink.
struct MacPoster: View {
    let item: UnifiedMediaItem
    /// Fixed width for horizontal rails (carousels). `nil` = fill the container
    /// (grid cell), so library/search grids reflow responsively as the window
    /// resizes instead of clipping fixed-width posters.
    var width: CGFloat? = nil
    @Environment(\.watchedDisplay) private var watchedDisplay
    @Environment(\.posterRatingSource) private var posterRatingSource
    /// Netflix-availability badge (#360); optional so previews still render.
    @Environment(WatchAvailabilityStore.self) private var availability: WatchAvailabilityStore?
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CachedAsyncImage(url: item.posterURL, aspectRatio: 2.0 / 3.0)
                .frame(maxWidth: width ?? .infinity)
                .watchedArtwork(item.isFullyWatched, display: watchedDisplay)
                // Compact community-rating chip in the top-leading corner (#351)
                // — just the score, so it barely takes space. Hidden when absent.
                .overlay(alignment: .topLeading) { ratingBadge }
                .overlay(alignment: .topTrailing) { netflixBadge }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(
                    color: .black.opacity(isHovered ? 0.40 : 0),
                    radius: isHovered ? 14 : 0,
                    y: isHovered ? 7 : 0
                )
            Text(item.title)
                .font(.callout)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
                .foregroundStyle(item.isFullyWatched ? .secondary : .primary)
                .frame(maxWidth: width ?? .infinity, minHeight: 40, alignment: .topLeading)
            if let year = item.year {
                Text(String(year)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: width)
        // Scale up from the bottom so posters in a row lift without reflowing
        // the text beneath them or crowding adjacent cards.
        .scaleEffect(isHovered ? 1.045 : 1.0, anchor: .bottom)
        .animation(.spring(response: 0.22, dampingFraction: 0.82), value: isHovered)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var ratingBadge: some View {
        if let rating = item.posterRating(source: posterRatingSource), rating > 0 {
            Text(String(format: "%.1f", rating))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay { Capsule().stroke(.white.opacity(0.15), lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                .padding(6)
        }
    }

    /// "Also on Netflix" badge (#360) — the TMDb-served logo, top-trailing.
    @ViewBuilder
    private var netflixBadge: some View {
        if let url = availability?.netflixLogoURL(for: item) {
            CachedAsyncImage(url: url, aspectRatio: 1)
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(.white.opacity(0.15), lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                .padding(6)
                .accessibilityLabel(Text("On Netflix"))
        }
    }
}
