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

    @Environment(WatchAvailabilityStore.self) private var availability: WatchAvailabilityStore?
    @Environment(\.posterRatingSource) private var posterRatingSource

    @State private var items: [MediaItem] = []
    @State private var sort: LibrarySort = .default
    @State private var isLoadingPage = false
    @State private var loadError: String?
    @State private var hasMore = true
    @State private var didInitialLoad = false
    /// Items in *this* library that have a resume point in `ResumeStore`,
    /// surfaced as a horizontal rail above the grid. Refreshed every time a
    /// page lands; the set grows as the user scrolls deeper.
    @State private var continueWatching: [HomeFeed.ContinueWatchingEntry] = []
    /// tvOS sort picker presentation. iOS / iPadOS / visionOS use the
    /// toolbar Menu — `.primaryAction` placement isn't honoured on tvOS, and
    /// `Menu` doesn't render its options in a usable way there either, so
    /// tvOS gets a focusable inline button that flips this and presents a
    /// sheet of options.
    @State private var isSortSheetPresented = false

    /// Items per fetch. Big enough that most libraries finish in 1–2 pages,
    /// small enough that a slow connection still feels responsive.
    private static let pageSize = 100

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                // tvOS: an in-scroll heading that scrolls away with the grid.
                // `.navigationTitle` on tvOS pins a persistent title that never
                // moves and overlaps the top tab-bar region — it can displace
                // the tab bar and strand focus on return from a pushed Detail
                // (#243). Same treatment as UnifiedLibraryGridView (#216).
                #if os(tvOS)
                Text(library.title)
                    .font(AetherDesign.Typography.heroTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                #endif
                content
            }
            .padding(.horizontal, AetherDesign.Spacing.l)
            .padding(.vertical, AetherDesign.Spacing.l)
        }
        .aetherScreenBackground()
        #if !os(tvOS)
        .navigationTitle(library.title)
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        #if !os(tvOS)
        // iOS / iPadOS / visionOS: native toolbar Menu pattern. tvOS
        // doesn't honour `.primaryAction` placement and won't render the
        // Menu's options usefully, so it uses the inline trigger inside
        // `content` instead (see `tvOSSortTrigger`).
        .toolbar { sortToolbarItem }
        #else
        .sheet(isPresented: $isSortSheetPresented) { tvOSSortSheet }
        #endif
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
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                #if os(tvOS)
                tvOSSortTrigger
                #endif
                if !continueWatching.isEmpty {
                    continueWatchingSection
                }
                grid
            }
        }
    }

    // MARK: - tvOS sort trigger + sheet

    #if os(tvOS)
    /// Focusable button at the top of the library content that opens the
    /// sort picker as a sheet. Lives here because tvOS doesn't honour the
    /// toolbar `Menu` pattern the way iOS does.
    private var tvOSSortTrigger: some View {
        Button {
            isSortSheetPresented = true
        } label: {
            HStack(spacing: AetherDesign.Spacing.s) {
                Image(systemName: sort.systemImage)
                Text("Sort: \(sort.displayName)")
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
            }
            .font(AetherDesign.Typography.cardTitle)
            .padding(.vertical, AetherDesign.Spacing.m)
            .padding(.horizontal, AetherDesign.Spacing.l)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule().stroke(AetherDesign.Palette.separator, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sort library")
        .accessibilityValue(sort.displayName)
    }

    private var tvOSSortSheet: some View {
        NavigationStack {
            List(LibrarySort.allCases, id: \.self) { option in
                Button {
                    selectSort(option)
                    isSortSheetPresented = false
                } label: {
                    HStack {
                        Label(option.displayName, systemImage: option.systemImage)
                        Spacer()
                        if option == sort {
                            Image(systemName: "checkmark")
                                .foregroundStyle(AetherDesign.Palette.accent)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Sort by")
        }
    }
    #endif

    /// Apply a new sort if different, persist preference, reload first page.
    /// Centralised so the iOS Menu and the tvOS sheet share the same code path.
    private func selectSort(_ option: LibrarySort) {
        guard option != sort else { return }
        sort = option
        Task {
            await libraryPreferences.setSort(option, for: library.id)
            await loadFirstPage()
        }
    }

    // MARK: - Continue Watching

    /// Horizontal rail above the grid, mirrors `HomeView.continueWatchingSection`
    /// but scoped to *this* library's currently-loaded items. Hidden when
    /// `continueWatching` is empty — `content` checks before calling.
    private var continueWatchingSection: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            AetherSectionHeader(
                title: "Continue Watching",
                subtitle: "Pick up where you left off"
            )

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: AetherDesign.Spacing.l) {
                    ForEach(continueWatching) { entry in
                        NavigationLink(value: entry.item) {
                            AetherCard.episode(
                                title: entry.item.title,
                                thumbURL: entry.item.backdropURL ?? entry.item.posterURL,
                                progress: entry.progress
                            )
                            .frame(width: continueCardWidth)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, AetherDesign.Spacing.xs)
            }
            #if os(tvOS)
            .focusSection()
            #endif
        }
    }

    private var continueCardWidth: CGFloat {
        #if os(tvOS)
        return 480
        #else
        return 296
        #endif
    }

    /// Walk the currently-loaded `items`, ask `ResumeStore` for each, build a
    /// list of `ContinueWatchingEntry` sorted by most recently watched first.
    /// Cheap: it's a dictionary lookup per item against an in-memory store.
    private func refreshContinueWatching() async {
        var entries: [HomeFeed.ContinueWatchingEntry] = []
        for item in items {
            if let point = await resumeStore.point(for: item.id) {
                entries.append(.init(item: item, resume: point))
            }
        }
        continueWatching = entries.sorted { $0.resume.updatedAt > $1.resume.updatedAt }
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: AetherDesign.Spacing.l) {
            ForEach(items) { item in
                NavigationLink(value: item) {
                    AetherCard.poster(title: item.title, posterURL: item.posterURL, isWatched: item.isFullyWatched, rating: item.posterRating(source: posterRatingSource), netflixLogoURL: availability?.netflixLogoURL(for: item))
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
                        selectSort(option)
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
            await refreshContinueWatching()
        } catch {
            loadError = error.localizedDescription
            hasMore = false
        }
    }
}
