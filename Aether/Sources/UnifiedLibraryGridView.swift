import SwiftUI
import AetherCore

/// Full unified grid of every title of one kind (Movies / TV Shows) across all
/// connected sources — the "See all" target from `LibraryBrowseView`.
///
/// Deduplicated like the rest of the unified surfaces: a title on both Plex and
/// Jellyfin appears once, and each card navigates a `UnifiedMediaItem` (Detail
/// shows its Available Sources). Pushed into the Library `NavigationStack`, so
/// the `UnifiedMediaItem` destination is already registered by
/// `mediaNavigationDestinations`.
struct UnifiedLibraryGridView: View {
    let title: String
    let kind: MediaItem.Kind
    let connectedSources: [any MediaSource]
    let downloadStore: DownloadStore?

    @State private var items: [UnifiedMediaItem] = []
    @State private var isLoading = false

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, AetherDesign.Spacing.l)
                .padding(.vertical, AetherDesign.Spacing.l)
        }
        .background(AetherDesign.Palette.background.ignoresSafeArea())
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .task(id: sourcesKey) { await load() }
    }

    private var sourcesKey: String {
        connectedSources.map { $0.id.stableKey }.sorted().joined(separator: ",")
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && items.isEmpty {
            AetherLoadingState(.inline)
                .padding(.top, AetherDesign.Spacing.l)
        } else if items.isEmpty {
            AetherEmptyState(
                glyph: "tray",
                title: "Nothing here yet",
                message: "No \(title.lowercased()) found across your connected sources."
            )
        } else {
            LazyVGrid(columns: columns, spacing: AetherDesign.Spacing.l) {
                ForEach(items) { item in
                    NavigationLink(value: item) {
                        AetherCard.poster(title: item.title, posterURL: item.posterURL)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var columns: [GridItem] {
        #if os(tvOS)
        [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: AetherDesign.Spacing.l)]
        #else
        [GridItem(.adaptive(minimum: 120, maximum: 180), spacing: AetherDesign.Spacing.m)]
        #endif
    }

    private func load() async {
        guard !connectedSources.isEmpty else {
            items = []
            return
        }
        isLoading = true
        defer { isLoading = false }
        let library = UnifiedLibrary(sources: connectedSources, downloads: downloadStore)
        items = await library.unifiedItems(kind: kind)
    }
}
