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
///
/// Sorting is **client-side** over the loaded unified items (no per-source
/// server sort, since the grid spans sources). The control mirrors
/// `LibraryView`: a toolbar `Menu` on iOS / iPadOS / visionOS, an inline
/// button + sheet on tvOS (which doesn't render toolbar menus usefully).
struct UnifiedLibraryGridView: View {
    let title: String
    let kind: MediaItem.Kind
    let connectedSources: [any MediaSource]
    let downloadStore: DownloadStore?

    @State private var items: [UnifiedMediaItem] = []
    @State private var isLoading = false
    @State private var sort: LibrarySort = .titleAZ
    #if os(tvOS)
    @State private var isSortSheetPresented = false
    #endif

    /// Cross-source sorts that work without server-side ordering or per-item
    /// ratings. (Recently-added / rating need signals the unified item doesn't
    /// carry, so they're intentionally omitted here.)
    private let sortOptions: [LibrarySort] = [.titleAZ, .titleZA, .yearNewest, .yearOldest]

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
        #if !os(tvOS)
        .toolbar { sortToolbarItem }
        #else
        .sheet(isPresented: $isSortSheetPresented) { tvOSSortSheet }
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
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                #if os(tvOS)
                tvOSSortTrigger
                #endif
                LazyVGrid(columns: columns, spacing: AetherDesign.Spacing.l) {
                    ForEach(sortedItems) { item in
                        NavigationLink(value: item) {
                            AetherCard.poster(title: item.title, posterURL: item.posterURL)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var sortedItems: [UnifiedMediaItem] {
        switch sort {
        case .titleAZ:
            return items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .titleZA:
            return items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
        case .yearNewest:
            return items.sorted { ($0.year ?? Int.min) > ($1.year ?? Int.min) }
        case .yearOldest:
            return items.sorted { ($0.year ?? Int.max) < ($1.year ?? Int.max) }
        case .recentlyAdded, .ratingHighest, .random:
            // Not supported cross-source; keep the merge (source) order.
            return items
        }
    }

    private var columns: [GridItem] {
        #if os(tvOS)
        [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: AetherDesign.Spacing.l)]
        #else
        [GridItem(.adaptive(minimum: 120, maximum: 180), spacing: AetherDesign.Spacing.m)]
        #endif
    }

    // MARK: - Sort UI

    #if !os(tvOS)
    private var sortToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                ForEach(sortOptions, id: \.self) { option in
                    Button {
                        sort = option
                    } label: {
                        Label(option.displayName, systemImage: option.systemImage)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
        }
    }
    #else
    /// tvOS inline sort button — toolbar menus don't render usefully on tvOS,
    /// so it opens a focusable sheet (same approach as `LibraryView`).
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
            .overlay { Capsule().stroke(AetherDesign.Palette.separator, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sort")
        .accessibilityValue(sort.displayName)
    }

    private var tvOSSortSheet: some View {
        NavigationStack {
            List(sortOptions, id: \.self) { option in
                Button {
                    sort = option
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

    // MARK: - Loading

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
