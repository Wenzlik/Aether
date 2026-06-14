import SwiftUI
import AetherCore

/// A library poster card. Watched titles get the **shared mobile treatment**
/// (#280): desaturation + a black wash + a centered "WATCHED" wordmark + the
/// gold corner ribbon — tuned by the user's Settings (`\.watchedDisplay`), not
/// just a tiny checkmark. Pure visual — call sites wrap it in a NavigationLink.
struct MacPoster: View {
    let item: UnifiedMediaItem
    var width: CGFloat = 150
    @Environment(\.watchedDisplay) private var watchedDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CachedAsyncImage(url: item.posterURL, aspectRatio: 2.0 / 3.0)
                .frame(width: width)
                .watchedArtwork(item.isFullyWatched, display: watchedDisplay)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(item.title)
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(item.isFullyWatched ? .secondary : .primary)
                .frame(width: width, alignment: .leading)
            if let year = item.year {
                Text(String(year)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
