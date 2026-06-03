import SwiftUI
import AetherCore

/// Search-results body shared by `HomeView` and `LibraryBrowseView`.
///
/// Both tabs carry a `.searchable` modifier — when the user starts
/// typing, the host view swaps its normal content (rails / Library
/// grid) for this view, scoped to the same source. Same logic that
/// used to live in the dedicated Search tab; lifted out so removing
/// the tab didn't mean losing search.
///
/// **Data:** the host owns the `query` binding and the source. This
/// view loads one page of items per library on appear, dedupes by
/// `MediaID`, and filters client-side by `title.localizedCaseInsensitiveContains`.
/// No new endpoint, no pagination beyond what the source already
/// returns — the same trade-off the previous SearchView made.
struct MediaSearchResults: View {
    let source: (any MediaSource)?
    let query: String

    @State private var allItems: [MediaItem] = []
    @State private var isLoading = false

    var body: some View {
        content
            // Load lazily — first time the search results appear, pull
            // one page per library and cache for the rest of the
            // session. Source change (sign out / switch) re-loads.
            .task(id: source?.id) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if source == nil {
            AetherEmptyState(
                glyph: "magnifyingglass",
                title: "Nothing to search yet",
                message: "Connect a source and your movies and shows become searchable here."
            )
        } else if isLoading && allItems.isEmpty {
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
                    ForEach(results) { item in
                        NavigationLink(value: item) {
                            AetherCard.poster(title: item.title, posterURL: item.posterURL)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(AetherDesign.Spacing.l)
            }
        }
    }

    private var results: [MediaItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return allItems.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }

    private var columns: [GridItem] {
        #if os(tvOS)
        [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: AetherDesign.Spacing.l)]
        #else
        [GridItem(.adaptive(minimum: 120, maximum: 180), spacing: AetherDesign.Spacing.m)]
        #endif
    }

    /// One page of items per library, deduped. Triggered by the
    /// `.task(id: source?.id)` modifier in `body`. Cheap on small
    /// libraries, bounded by the source's default page size on big ones.
    private func load() async {
        guard let source else {
            allItems = []
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let libraries = try await source.libraries()
            var seen = Set<MediaID>()
            var collected: [MediaItem] = []
            for library in libraries {
                let items = try await source.items(in: library.id)
                for item in items where seen.insert(item.id).inserted {
                    collected.append(item)
                }
            }
            allItems = collected
        } catch {
            allItems = []
        }
    }
}
