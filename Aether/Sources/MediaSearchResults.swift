import SwiftUI
import AetherCore

/// Search-results body shared by `HomeView` and `LibraryBrowseView`.
///
/// Both tabs carry a search field — when the user types, the host swaps its
/// content (rails / grid) for this view. It searches **across every source it's
/// given** and returns **unified** results: one row per title, deduplicated via
/// the same external-ID merge as Home. Home passes all connected sources
/// (unified search); Library passes its single active source (until Library is
/// unified in a later phase).
///
/// **Data:** loads one page of items per library per source on appear, merges +
/// dedupes, and filters client-side by `title.localizedCaseInsensitiveContains`.
/// Each result navigates the `UnifiedMediaItem` itself, so Detail receives the
/// full source list for its "Available Sources" section.
struct MediaSearchResults: View {
    let sources: [any MediaSource]
    let query: String

    @State private var items: [UnifiedMediaItem] = []
    @State private var isLoading = false

    var body: some View {
        content
            .task(id: sourcesKey) { await load() }
    }

    /// Stable reload key across the given sources.
    private var sourcesKey: String {
        sources.map { $0.id.stableKey }.sorted().joined(separator: ",")
    }

    @ViewBuilder
    private var content: some View {
        if sources.isEmpty {
            AetherEmptyState(
                glyph: "magnifyingglass",
                title: "Nothing to search yet",
                message: "Connect a source and your movies and shows become searchable here."
            )
        } else if isLoading && items.isEmpty {
            AetherLoadingState(.inline)
                .padding(.top, AetherDesign.Spacing.l)
        } else if results.isEmpty {
            AetherEmptyState(
                glyph: "questionmark.circle",
                title: "No matches",
                message: "Nothing in your library matches “\(query)”."
            )
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: AetherDesign.Spacing.l) {
                    ForEach(results) { unified in
                        NavigationLink(value: unified) {
                            AetherCard.poster(title: unified.title, posterURL: unified.posterURL, isWatched: unified.isWatched)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(AetherDesign.Spacing.l)
            }
        }
    }

    private var results: [UnifiedMediaItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return items.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }

    private var columns: [GridItem] {
        #if os(tvOS)
        [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: AetherDesign.Spacing.l)]
        #else
        [GridItem(.adaptive(minimum: 120, maximum: 180), spacing: AetherDesign.Spacing.m)]
        #endif
    }

    /// One page of items per library across every source, merged + deduped.
    /// Fault-tolerant: a source that fails to list/fetch is skipped.
    private func load() async {
        guard !sources.isEmpty else {
            items = []
            return
        }
        isLoading = true
        defer { isLoading = false }

        var collected: [MediaItem] = []
        for source in sources {
            guard let libraries = try? await source.libraries() else { continue }
            for library in libraries {
                if let fetched = try? await source.items(in: library.id) {
                    collected += fetched
                }
            }
        }
        items = UnifiedLibrary.merge(collected)
    }
}
