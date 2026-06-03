import SwiftUI
import AetherCore

/// The Search tab. Client-side title search over the items Aether has already
/// loaded — no new backend, just `.searchable` filtering across the source's
/// libraries. Results push the same `DetailView` as everywhere else.
struct SearchView: View {
    let source: (any MediaSource)?
    let resumeStore: ResumeStore
    let playbackSession: PlaybackSession
    let libraryPreferences: LibraryPreferencesStore
    /// Forwarded to `mediaNavigationDestinations` so Detail can wire the
    /// Download button. Optional — `nil` before `AppSession.start()`.
    let downloadManager: DownloadManager?
    let downloads: DownloadObserver?

    @State private var allItems: [MediaItem] = []
    @State private var isLoading = false
    @State private var query = ""

    var body: some View {
        NavigationStack {
            content
                .background(AetherDesign.Gradients.background.ignoresSafeArea())
                .searchable(text: $query, prompt: "Search your library")
                .mediaNavigationDestinations(
                    source: source,
                    resumeStore: resumeStore,
                    playbackSession: playbackSession,
                    libraryPreferences: libraryPreferences,
                    downloadManager: downloadManager,
                    downloads: downloads
                )
        }
        .task(id: source?.id) { await load() }
    }

    private var results: [MediaItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return allItems.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }

    @ViewBuilder
    private var content: some View {
        if source == nil {
            AetherEmptyState(
                glyph: "magnifyingglass",
                title: "Nothing to search yet",
                message: "Connect a source and your movies and shows become searchable here."
            )
        } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            AetherEmptyState(
                glyph: "magnifyingglass",
                title: "Search your library",
                message: "Find any movie or show by title across your connected source."
            )
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

    private var columns: [GridItem] {
        #if os(tvOS)
        [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: AetherDesign.Spacing.l)]
        #else
        [GridItem(.adaptive(minimum: 120, maximum: 180), spacing: AetherDesign.Spacing.m)]
        #endif
    }

    /// Pull one page of items from every library and flatten into a single
    /// searchable set. Deduped by id in case a title appears in more than one
    /// library response.
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
