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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CachedAsyncImage(url: item.posterURL, aspectRatio: 2.0 / 3.0)
                .frame(maxWidth: width ?? .infinity)
                .watchedArtwork(item.isFullyWatched, display: watchedDisplay)
                // Compact community-rating chip in the top-leading corner (#351)
                // — just the score, so it barely takes space. Hidden when absent.
                .overlay(alignment: .topLeading) { ratingBadge }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(item.title)
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(item.isFullyWatched ? .secondary : .primary)
                .frame(maxWidth: width ?? .infinity, alignment: .leading)
            if let year = item.year {
                Text(String(year)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: width)
    }

    @ViewBuilder
    private var ratingBadge: some View {
        if let rating = item.communityRating, rating > 0 {
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
}
