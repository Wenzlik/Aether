import SwiftUI
import AetherCore

/// The Library tab root — Aether's browse hub, now **unified** across every
/// connected source.
///
/// The source is an implementation detail here too: one deduplicated catalog,
/// not a per-server picker. Layout:
/// - a branded hero header ("Aether" + search field),
/// - a Downloaded rail (when there are downloads),
/// - a Continue Watching rail (cross-source, best resume per title),
/// - **Movies** and **TV Shows** rails, each with a "See all" link that pushes a
///   full unified grid (`UnifiedLibraryGridView`).
///
/// Reuses `UnifiedLibrary.homeRails(...)` — the same aggregator Home uses — so
/// the data layer isn't duplicated. Cards navigate `UnifiedMediaItem`, so Detail
/// shows the title's Available Sources.
struct LibraryBrowseView: View {
    /// Every connected source — aggregated + deduplicated by `UnifiedLibrary`.
    let connectedSources: [any MediaSource]
    /// Backs the unified aggregator's offline fold-in.
    let downloadStore: DownloadStore?
    let resumeStore: ResumeStore
    let playbackSession: PlaybackSession
    let libraryPreferences: LibraryPreferencesStore
    let onAddSource: () -> Void
    /// Forwarded to `mediaNavigationDestinations` so Detail can wire the
    /// Download button. Optional — `nil` before `AppSession.start()`.
    let downloadManager: DownloadManager?
    let downloads: DownloadObserver?
    /// Forwarded so DetailView can seed Audio / Subtitle / Quality pickers
    /// from the user's Settings defaults.
    let playbackPreferences: PlaybackPreferencesStore?

    @State private var rails: UnifiedRails = .empty
    @State private var isLoading = false
    @State private var loadError: String?
    /// Drives the `NavigationStack` so a rail's "See all" can push the full
    /// unified grid. Card taps push via `NavigationLink`.
    @State private var navigationPath = NavigationPath()

    /// When non-empty, the library swaps its rails for unified `MediaSearchResults`.
    @State private var searchQuery = ""
    /// Owns keyboard focus so tapping outside / scrolling / selecting a result
    /// dismisses the keyboard.
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if shouldShowBrandedChrome {
                    VStack(spacing: 0) {
                        brandedHeader
                        content
                            .simultaneousGesture(TapGesture().onEnded { searchFocused = false })
                    }
                } else {
                    content
                }
            }
            // `scrollDismissesKeyboard` is unavailable on visionOS; tap-outside
            // + Search/Done still dismiss there.
            #if os(iOS)
            .scrollDismissesKeyboard(.immediately)
            #endif
            .background(AetherDesign.Gradients.background.ignoresSafeArea())
            .mediaNavigationDestinations(
                source: connectedSources.first,
                connectedSources: connectedSources,
                resumeStore: resumeStore,
                playbackSession: playbackSession,
                libraryPreferences: libraryPreferences,
                downloadManager: downloadManager,
                downloads: downloads,
                playbackPreferences: playbackPreferences
            )
            // "See all" → full unified grid for a kind.
            .navigationDestination(for: UnifiedLibrarySection.self) { section in
                UnifiedLibraryGridView(
                    title: section.title,
                    kind: section.kind,
                    connectedSources: connectedSources,
                    downloadStore: downloadStore
                )
            }
        }
        .task(id: sourcesKey) { await load() }
    }

    /// Reload key: the connected source ids (so sign-in / sign-out rebuilds).
    private var sourcesKey: String {
        connectedSources.map { $0.id.stableKey }.sorted().joined(separator: ",")
    }

    /// Show the centered Aether lockup + search field above content on the
    /// rails and during search. The empty / no-source / loading / error states
    /// own their own full-screen layout, so the header sits out for those.
    private var shouldShowBrandedChrome: Bool {
        if isSearching { return true }
        if connectedSources.isEmpty { return false }
        if loadError != nil, rails.isEmpty { return false }
        if isLoading && rails.isEmpty { return false }
        if rails.isEmpty { return false }
        return true
    }

    private var brandedHeader: some View {
        VStack(spacing: AetherDesign.Spacing.m) {
            AetherWordmark(.large)
                .frame(maxWidth: .infinity)
            AetherSearchField(text: $searchQuery, prompt: "Search your library", focus: $searchFocused)
        }
        .padding(.horizontal, AetherDesign.Spacing.l)
        .padding(.top, AetherDesign.Spacing.l)
        .padding(.bottom, AetherDesign.Spacing.m)
    }

    /// True when the user has typed something — rails get replaced with unified
    /// search results.
    private var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var content: some View {
        if isSearching {
            // Unified search across every connected source (same as Home / Search).
            MediaSearchResults(sources: connectedSources, query: searchQuery)
        } else if connectedSources.isEmpty {
            AetherEmptyState(
                glyph: "rectangle.stack",
                title: "No library yet",
                message: "Connect a source and your Aether library appears here.",
                action: .init(label: "Add a source", run: onAddSource)
            )
        } else if let loadError, rails.isEmpty {
            AetherErrorState(
                title: "Couldn't load your library",
                message: loadError,
                retry: .init { Task { await load() } }
            )
        } else if isLoading && rails.isEmpty {
            AetherLoadingState(.rails(count: 2))
                .padding(.top, AetherDesign.Spacing.l)
        } else if rails.isEmpty {
            AetherEmptyState(
                glyph: "tray",
                title: "Library is empty",
                message: "Add some movies or shows to a connected source and they'll surface here."
            )
        } else {
            railsContent
        }
    }

    // MARK: - Rails

    private var railsContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                if hasAnyDownloads {
                    downloadedRail
                }
                if !rails.continueWatching.isEmpty {
                    continueWatchingRail
                }
                if !rails.movies.isEmpty {
                    unifiedRail(title: "Movies", kind: .movie, items: rails.movies)
                }
                if !rails.shows.isEmpty {
                    unifiedRail(title: "TV Shows", kind: .show, items: rails.shows)
                }
            }
            .padding(.top, AetherDesign.Spacing.l)
            .padding(.bottom, AetherDesign.Spacing.xxl)
        }
    }

    /// `true` once there's at least one completed download — gates the
    /// Downloaded rail. Management lives in Settings → Downloads; Library only
    /// surfaces them as content.
    private var hasAnyDownloads: Bool {
        !(downloads?.snapshot.completed.isEmpty ?? true)
    }

    /// "Downloaded" rail — completed items, newest first, straight from the
    /// download observer's snapshot (valid offline).
    private var downloadedRail: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            AetherSectionHeader(title: "Downloaded")

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: AetherDesign.Spacing.l) {
                    ForEach(downloads?.snapshot.completed ?? []) { job in
                        downloadedCard(job)
                    }
                }
                .padding(.horizontal, AetherDesign.Spacing.l)
                .padding(.vertical, AetherDesign.Spacing.xs)
            }
            .aetherFocusSection()
        }
    }

    /// Card for a downloaded job. Rendered from the job's captured snapshot
    /// (title + poster + episode context) so it reads correctly offline.
    /// Tapping pushes a `MediaItem` that `mediaNavigationDestinations` routes.
    private func downloadedCard(_ job: DownloadJob) -> some View {
        let item = MediaItem(
            id: job.mediaID,
            title: job.title,
            kind: job.kind,
            posterURL: job.posterURL,
            seriesTitle: job.seriesTitle,
            seasonNumber: job.seasonNumber,
            episodeNumber: job.episodeNumber
        )

        return NavigationLink(value: item) {
            AetherCard.poster(title: item.displayTitle, posterURL: item.posterURL)
                .frame(width: posterWidth)
        }
        .buttonStyle(.plain)
    }

    /// Cross-source "Continue Watching" — best resume per title.
    private var continueWatchingRail: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            AetherSectionHeader(title: "Continue Watching")

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: AetherDesign.Spacing.l) {
                    ForEach(rails.continueWatching) { entry in
                        NavigationLink(value: entry.item) {
                            AetherCard.episode(
                                title: entry.item.title,
                                thumbURL: entry.item.backdropURL ?? entry.item.posterURL,
                                progress: entry.progress
                            )
                            .frame(width: episodeCardWidth)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, AetherDesign.Spacing.l)
                .padding(.vertical, AetherDesign.Spacing.xs)
            }
            .aetherFocusSection()
        }
    }

    /// A unified poster rail (Movies / TV Shows) with a "See all" that pushes
    /// the full grid for that kind.
    private func unifiedRail(title: String, kind: MediaItem.Kind, items: [UnifiedMediaItem]) -> some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            AetherSectionHeader(
                title: title,
                accessoryTitle: "See all",
                accessoryAction: { @MainActor in
                    navigationPath.append(UnifiedLibrarySection(kind: kind, title: title))
                }
            )

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: AetherDesign.Spacing.l) {
                    ForEach(items.prefix(12)) { item in
                        NavigationLink(value: item) {
                            AetherCard.poster(title: item.title, posterURL: item.posterURL)
                                .frame(width: posterWidth)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, AetherDesign.Spacing.l)
                .padding(.vertical, AetherDesign.Spacing.xs)
            }
            .aetherFocusSection()
        }
    }

    // MARK: - Sizing

    private var posterWidth: CGFloat {
        #if os(tvOS)
        300
        #else
        140
        #endif
    }

    private var episodeCardWidth: CGFloat {
        #if os(tvOS)
        480
        #else
        296
        #endif
    }

    // MARK: - Loading

    private func load() async {
        loadError = nil
        guard !connectedSources.isEmpty else {
            rails = .empty
            return
        }
        isLoading = true
        defer { isLoading = false }
        let library = UnifiedLibrary(sources: connectedSources, downloads: downloadStore)
        rails = await library.homeRails(resumeStore: resumeStore)
    }
}

/// "See all" push target — a full unified grid for one media kind.
struct UnifiedLibrarySection: Hashable {
    let kind: MediaItem.Kind
    let title: String
}

private extension View {
    /// Apply `.focusSection()` on tvOS for predictable D-pad movement between
    /// rails; no-op elsewhere (the API is tvOS-only).
    @ViewBuilder
    func aetherFocusSection() -> some View {
        #if os(tvOS)
        self.focusSection()
        #else
        self
        #endif
    }
}
