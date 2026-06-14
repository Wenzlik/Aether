import SwiftUI
import AetherCore

/// Detail screen for a library item. Movies (and episodes) show a Play button;
/// containers (shows / seasons) drill down — a show lists its seasons (which
/// push another detail), a season lists its episodes with inline Play. Pushed
/// onto the library's `NavigationStack`; recursion happens through the shared
/// `navigationDestination(for: MediaItem.self)`.
struct MediaDetailView: View {
    let session: MacSession
    let item: MediaItem
    /// Resolve + open a player window for a playable (non-container) item.
    let onPlay: (MediaItem) -> Void

    @State private var children: [MediaItem] = []
    @State private var isLoading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if !item.kind.isContainer {
                    Button { onPlay(item) } label: {
                        Label("Play", systemImage: "play.fill").frame(maxWidth: 220)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                }
                if let overview = item.summary, !overview.isEmpty {
                    Text(overview)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 720, alignment: .leading)
                }
                if item.kind.isContainer {
                    childrenSection
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(item.title)
        .task(id: item.id) { await load() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            CachedAsyncImage(url: item.posterURL, aspectRatio: 2.0 / 3.0)
                .frame(width: 180)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 8) {
                Text(item.title).font(.largeTitle.bold())
                HStack(spacing: 10) {
                    if let year = item.year { Text(String(year)) }
                    if let rating = item.contentRating { Text(rating) }
                    if let community = item.communityRating {
                        Label(String(format: "%.1f", community), systemImage: "star.fill")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Children (seasons / episodes)

    @ViewBuilder
    private var childrenSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.kind == .show ? "Seasons" : "Episodes")
                .font(.title2.bold())
            if isLoading && children.isEmpty {
                ProgressView().padding(.vertical, 8)
            } else {
                ForEach(children, id: \.id) { child in
                    if child.kind.isContainer {
                        NavigationLink(value: child) { childRow(child) }
                            .buttonStyle(.plain)
                    } else {
                        HStack {
                            childRow(child)
                            Spacer()
                            Button { onPlay(child) } label: { Image(systemName: "play.fill") }
                                .buttonStyle(.borderless)
                        }
                    }
                    Divider()
                }
            }
        }
    }

    private func childRow(_ child: MediaItem) -> some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: child.posterURL, aspectRatio: child.kind == .episode ? 16.0 / 9.0 : 2.0 / 3.0)
                .frame(width: child.kind == .episode ? 120 : 54)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(child.kind == .episode ? DetailFormatting.episodeLabel(child) : child.title)
                    .font(.body)
                if let summary = child.summary, child.kind == .episode, !summary.isEmpty {
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func load() async {
        guard item.kind.isContainer else { return }
        isLoading = true
        children = await session.children(of: item)
        isLoading = false
    }
}
