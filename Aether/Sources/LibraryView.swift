import SwiftUI
import AetherCore

/// Full-grid view of one library's contents with sort + pagination.
///
/// Reached from `HomeView` by tapping a library section header (the
/// `accessoryAction` on `AetherSectionHeader`). The grid pulls one page of
/// items at a time, walks `offset` forward as the user scrolls, and persists
/// the chosen sort per-library in `LibraryPreferencesStore`.
///
/// Selection of an item still pushes `DetailView` via the same
/// `.navigationDestination(for: MediaItem.self)` that `HomeView` registers,
/// so no extra navigation wiring is needed here.
struct LibraryView: View {
    let library: Library
    let source: (any MediaSource)?
    let resumeStore: ResumeStore
    let playbackSession: PlaybackSession
    let libraryPreferences: LibraryPreferencesStore

    @State private var items: [MediaItem] = []
    @State private var sort: LibrarySort = .default
    @State private var isLoadingPage = false
    @State private var loadError: String?
    @State private var hasMore = true
    @State private var didInitialLoad = false

    /// Items per fetch. Big enough that most libraries finish in 1–2 pages,
    /// small enough that a slow connection still feels responsive.
    private static let pageSize = 100

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, AetherDesign.Spacing.l)
                .padding(.vertical, AetherDesign.Spacing.l)
        }
        .background(AetherDesign.Palette.background.ignoresSafeArea())
        .navigationTitle(library.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .toolbar { sortToolbarItem }
        .task {
            guard !didInitialLoad else { return }
            didInitialLoad = true
            sort = (await libraryPreferences.sort(for: library.id)) ?? .default
            await loadFirstPage()
        }
    }

    // MARK: - Content (states)

    @ViewBuilder
    private var content: some View {
        if let loadError, items.isEmpty {
            AetherErrorState(
                title: "Couldn't load \(library.title)",
                message: loadError,
                retry: .init { Task { await loadFirstPage() } }
            )
        } else if isLoadingPage && items.isEmpty {
            AetherLoadingState(.rails(count: 1))
        } else if items.isEmpty {
            AetherEmptyState(
                glyph: "tray",
                title: "This library is empty",
                message: "\(library.title) doesn't have any items Aether can show yet."
            )
        } else {
            grid
        }
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: AetherDesign.Spacing.l) {
            ForEach(items) { item in
                NavigationLink(value: item) {
                    AetherCard.poster(title: item.title, posterURL: item.posterURL)
                }
                .buttonStyle(.plain)
            }

            if hasMore && !items.isEmpty {
                // A zero-size sentinel at the end of the grid: when it scrolls
                // into view (LazyVGrid only renders visible cells), `.task`
                // fires and fetches the next page. Avoids attaching `.onAppear`
                // to the last card, which would re-fetch on every focus shift
                // on tvOS.
                Color.clear
                    .frame(height: 1)
                    .task { await loadMore() }
            }
        }
    }

    private var columns: [GridItem] {
        #if os(tvOS)
        // Couch distance — keep cells big and visible. Six columns fits 1080p
        // with the standard 24pt outer padding.
        return Array(repeating: GridItem(.flexible(), spacing: AetherDesign.Spacing.l), count: 6)
        #elseif os(visionOS)
        return [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: AetherDesign.Spacing.l)]
        #else
        return [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: AetherDesign.Spacing.m)]
        #endif
    }

    // MARK: - Sort

    private var sortToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                ForEach(LibrarySort.allCases, id: \.self) { option in
                    Button {
                        if option != sort {
                            sort = option
                            Task {
                                await libraryPreferences.setSort(option, for: library.id)
                                await loadFirstPage()
                            }
                        }
                    } label: {
                        if option == sort {
                            Label(option.displayName, systemImage: "checkmark")
                        } else {
                            Label(option.displayName, systemImage: option.systemImage)
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down.circle")
                    .accessibilityLabel("Sort")
            }
        }
    }

    // MARK: - Loading

    private func loadFirstPage() async {
        items = []
        hasMore = true
        loadError = nil
        await loadPage(offset: 0)
    }

    private func loadMore() async {
        guard hasMore, !isLoadingPage, !items.isEmpty else { return }
        await loadPage(offset: items.count)
    }

    private func loadPage(offset: Int) async {
        guard let source else {
            // No source — user signed out. Render the welcome state.
            items = []
            hasMore = false
            return
        }
        isLoadingPage = true
        defer { isLoadingPage = false }

        do {
            let page = try await source.items(
                in: library.id,
                sortedBy: sort,
                limit: Self.pageSize,
                offset: offset
            )
            if offset == 0 {
                items = page
            } else {
                items.append(contentsOf: page)
            }
            // Plex returns fewer than pageSize when there's nothing left to
            // serve; the same rule works for any source that honours `limit`.
            if page.count < Self.pageSize {
                hasMore = false
            }
        } catch {
            loadError = error.localizedDescription
            hasMore = false
        }
    }
}
