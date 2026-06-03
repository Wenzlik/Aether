import SwiftUI
import AetherCore

/// The Library tab root — Aether's browse hub.
///
/// Replaces the old "two big empty tiles" picker with a richer layout that
/// makes the library feel inhabited even before the user drills in:
/// - a branded hero header ("Aether Library" + tagline),
/// - a Continue Watching rail (cross-library, only when there's something to
///   resume),
/// - a Recently Added rail (interleaved across libraries),
/// - and a section per library with a horizontal poster rail and a "See all"
///   link that pushes the existing `LibraryView` grid.
///
/// Reuses `HomeFeedBuilder` so we don't duplicate the data layer — the same
/// per-library item fetch powers Home and Library, and the cross-library
/// resume / recents derive from a single source of truth.
struct LibraryBrowseView: View {
    let source: (any MediaSource)?
    let resumeStore: ResumeStore
    let playbackSession: PlaybackSession
    let libraryPreferences: LibraryPreferencesStore
    let onAddSource: () -> Void
    /// Forwarded to `mediaNavigationDestinations` so Detail can wire the
    /// Download button. Optional — `nil` before `AppSession.start()`.
    let downloadManager: DownloadManager?
    let downloads: DownloadObserver?

    @State private var feed: HomeFeed = .empty
    @State private var isLoading = false
    @State private var loadError: String?
    /// Drives the `NavigationStack` so a section's "See all" can push the
    /// per-library `LibraryView` grid. Card taps push via `NavigationLink`.
    @State private var navigationPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navigationPath) {
            content
                .background(AetherDesign.Gradients.background.ignoresSafeArea())
                .mediaNavigationDestinations(
                    source: source,
                    resumeStore: resumeStore,
                    playbackSession: playbackSession,
                    libraryPreferences: libraryPreferences,
                    downloadManager: downloadManager,
                    downloads: downloads
                )
                .navigationDestination(for: LibraryStorageDestination.self) { _ in
                    LibraryStorageView(
                        downloadManager: downloadManager,
                        downloads: downloads
                    )
                }
        }
        .task(id: source?.id) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if source == nil {
            AetherEmptyState(
                glyph: "rectangle.stack",
                title: "No library yet",
                message: "Connect a source and your Aether library appears here.",
                action: .init(label: "Add a source", run: onAddSource)
            )
        } else if let loadError, feed.libraries.isEmpty {
            AetherErrorState(
                title: "Couldn't load your libraries",
                message: loadError,
                retry: .init { Task { await load() } }
            )
        } else if isLoading && feed.libraries.isEmpty {
            AetherLoadingState(.rails(count: 2))
                .padding(.top, AetherDesign.Spacing.l)
        } else if feed.libraries.isEmpty {
            AetherEmptyState(
                glyph: "tray",
                title: "No libraries",
                message: "This source doesn't expose any movie or show libraries Aether can read yet."
            )
        } else {
            rails
        }
    }

    // MARK: - Rails

    private var rails: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                heroHeader

                if hasAnyDownloads {
                    storageRow
                    downloadedRail
                }

                if !feed.continueWatching.isEmpty {
                    continueWatchingRail
                }

                if !recentlyAdded.isEmpty {
                    recentlyAddedRail
                }

                ForEach(feed.libraries) { librarySection in
                    librarySectionRail(librarySection)
                }
            }
            .padding(.top, AetherDesign.Spacing.l)
            .padding(.bottom, AetherDesign.Spacing.xxl)
        }
    }

    /// `true` once the user has at least one completed download.
    /// The Downloaded rail and the Manage row only appear after that —
    /// no "empty downloads row" before the user has tried it.
    private var hasAnyDownloads: Bool {
        !(downloads?.snapshot.completed.isEmpty ?? true)
    }

    /// One-tap path to the Storage detail screen. Reads the total size
    /// from the live snapshot so it ticks as downloads complete.
    private var storageRow: some View {
        NavigationLink(value: LibraryStorageDestination()) {
            HStack(spacing: AetherDesign.Spacing.m) {
                Image(systemName: "internaldrive")
                    .font(AetherDesign.Typography.body)
                    .foregroundStyle(AetherDesign.Palette.accent)
                    .frame(width: 28)
                Text("Manage downloads")
                    .font(AetherDesign.Typography.body)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                Spacer(minLength: AetherDesign.Spacing.s)
                Text(formatBytes(totalDownloadBytes))
                    .font(AetherDesign.Typography.metadata)
                    .foregroundStyle(AetherDesign.Palette.textSecondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
            }
            .padding(.vertical, AetherDesign.Spacing.m)
            .padding(.horizontal, AetherDesign.Spacing.m)
            .background(
                RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                    .fill(AetherDesign.Materials.card)
            )
            .padding(.horizontal, AetherDesign.Spacing.l)
        }
        .buttonStyle(.plain)
    }

    private var totalDownloadBytes: Int64 {
        downloads?.snapshot.statusByJobID.values.reduce(0) { acc, status in
            if case let .completed(_, size) = status { return acc + size }
            return acc
        } ?? 0
    }

    /// "Downloaded" rail — cross-source completed items, newest first.
    /// Each card is a `NavigationLink` to the original DetailView (the
    /// download job carries `MediaID`, so the existing destination
    /// registration handles routing); offline override in PlaybackSession
    /// makes Play use the local file.
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

    /// Card for a downloaded job. We don't have the live `MediaItem` (it's
    /// in the source's library snapshot, which may not be loaded), so we
    /// render directly from the job's captured snapshot — title +
    /// posterURL stay valid offline. Tapping pushes a `MediaItemRef` that
    /// `mediaNavigationDestinations` routes to Detail.
    @ViewBuilder
    private func downloadedCard(_ job: DownloadJob) -> some View {
        // Find the live MediaItem (from any loaded library section) to
        // get the full metadata. Falls back to a synthetic item built
        // from the job snapshot so the card is tappable even before the
        // source has finished loading.
        let item = feed.libraries
            .flatMap { $0.items }
            .first { $0.id == job.mediaID }
            ?? MediaItem(
                id: job.mediaID,
                title: job.title,
                kind: .movie,
                posterURL: job.posterURL
            )

        NavigationLink(value: item) {
            AetherCard.poster(title: item.title, posterURL: item.posterURL)
                .frame(width: posterWidth)
        }
        .buttonStyle(.plain)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Hero header (branded)

    /// The branded library header: the large wordmark on top, then a smaller
    /// "Library" page label, then the tagline. The wordmark carries identity;
    /// "Library" tells the user where they are without competing with the
    /// brand.
    private var heroHeader: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
            AetherWordmark(.large)
            Text("Library")
                .font(AetherDesign.Typography.sectionTitle)
                .foregroundStyle(AetherDesign.Palette.textSecondary)
            Text("Your media, beautifully organized.")
                .font(AetherDesign.Typography.metadata)
                .foregroundStyle(AetherDesign.Palette.textTertiary)
                .padding(.top, AetherDesign.Spacing.xxs)
        }
        .padding(.horizontal, AetherDesign.Spacing.l)
    }

    // MARK: - Cross-library rails

    /// Cross-library "Continue Watching" — same data as Home, exposed here so
    /// the Library tab is useful even when the user opens it directly.
    private var continueWatchingRail: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            AetherSectionHeader(title: "Continue Watching")

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: AetherDesign.Spacing.l) {
                    ForEach(feed.continueWatching) { entry in
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

    /// Interleaved "Recently Added" rail. Plex / Jellyfin default-sort by
    /// `addedAt:desc`, so the first items in each per-library list are the
    /// newest. We round-robin across libraries so a single huge library
    /// doesn't dominate, then cap at 12 cards.
    private var recentlyAdded: [MediaItem] {
        var perLibrary = feed.libraries.map { Array($0.items.prefix(6)) }
        var merged: [MediaItem] = []
        merged.reserveCapacity(12)
        while merged.count < 12 {
            var added = false
            for i in 0..<perLibrary.count {
                if !perLibrary[i].isEmpty {
                    merged.append(perLibrary[i].removeFirst())
                    added = true
                    if merged.count >= 12 { break }
                }
            }
            if !added { break }
        }
        return merged
    }

    private var recentlyAddedRail: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            AetherSectionHeader(title: "Recently Added")

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: AetherDesign.Spacing.l) {
                    ForEach(recentlyAdded) { item in
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

    // MARK: - Per-library section

    /// One library's row: title with inline count + horizontal poster rail +
    /// "See all" link that pushes the existing `LibraryView` grid. The inline
    /// `(N)` format — "Movies (1,234)" — gives a sense of scale at a glance
    /// without taking a second line away from the artwork below.
    private func librarySectionRail(_ section: HomeFeed.LibrarySection) -> some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            AetherSectionHeader(
                title: sectionTitle(for: section),
                accessoryTitle: "See all",
                accessoryAction: { @MainActor in navigationPath.append(section.library) }
            )

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: AetherDesign.Spacing.l) {
                    ForEach(section.items.prefix(12)) { item in
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

    /// Section title with the item count baked in — `"Movies (1,234)"`. The
    /// count is a best-effort number from the first page of items the source
    /// returned; accurate for libraries that fit in one page, an honest lower
    /// bound for very large libraries (true `totalSize` plumbing is future
    /// work and the inline format makes the approximation unobtrusive).
    private func sectionTitle(for section: HomeFeed.LibrarySection) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let count = section.items.count
        guard count > 0 else { return section.library.title }
        let formatted = formatter.string(from: NSNumber(value: count)) ?? "\(count)"
        return "\(section.library.title) (\(formatted))"
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
        guard let source else {
            feed = .empty
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let builder = HomeFeedBuilder()
            feed = try await builder.build(source: source, resumeStore: resumeStore)
        } catch {
            feed = .empty
            loadError = error.localizedDescription
        }
    }
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
