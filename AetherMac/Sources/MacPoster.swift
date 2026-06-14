import SwiftUI
import AetherCore

/// A library poster card. Watched titles are **dimmed** with a badge (like the
/// mobile app's watched display) rather than only carrying a tiny checkmark.
/// Pure visual — call sites wrap it in a NavigationLink to the base MediaItem.
struct MacPoster: View {
    let item: UnifiedMediaItem
    var width: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CachedAsyncImage(url: item.posterURL, aspectRatio: 2.0 / 3.0)
                .frame(width: width)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .opacity(item.isFullyWatched ? 0.45 : 1)
                .overlay(alignment: .topTrailing) {
                    if item.isFullyWatched {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.title3)
                            .foregroundStyle(.white, .green)
                            .padding(6)
                            .shadow(radius: 2)
                    }
                }
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
