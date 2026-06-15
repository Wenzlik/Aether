import SwiftUI
import AetherCore

/// The Home tab — cinematic, content-first. No page chrome: the tab bar above
/// already says "Home", so the screen opens straight into artwork (Featured,
/// Continue Watching, then a rail per library). When no source is connected it
/// shows a welcoming hero instead of a utility dashboard.
struct HomeView: View {
    /// Lifted from `RootTabView` so re-selecting the Home tab can pop to root.
    @Binding var navigationPath: NavigationPath
    /// `nil` when no source is configured yet — Home shows its welcome state.
    let source: (any MediaSource)?
    let resumeStore: ResumeStore
    let playbackSession: PlaybackSession
    let libraryPreferences: LibraryPreferencesStore
    let isPlexSignedIn: Bool
    let plexServerName: String?
    let plexDiscoveryState: AppSession.DiscoveryState
    let onAddSource: () -> Void
    let onRetryDiscovery: () -> Void
    /// Forwarded to `mediaNavigationDestinations` so Detail can wire the
    /// Download button. Optional — `nil` before `AppSession.start()` has
    /// booted the downloads pipeline.
    let downloadManager: DownloadManager?
    let downloads: DownloadObserver?
    /// Forwarded so DetailView can seed Audio / Subtitle / Quality pickers
    /// from the user's Settings defaults.
    let playbackPreferences: PlaybackPreferencesStore?
    /// All connected sources — when non-empty, Home renders **unified**
    /// (deduplicated) rails across them instead of a single source's libraries.
    let connectedSources: [any MediaSource]
    /// `true` while `AppSession` is still starting up / discovering. While it is,
    /// an empty feed means "still connecting" → show loading, not the welcome /
    /// empty state.
    let isConnecting: Bool
    /// Backs the unified aggregator's offline fold-in.
    let downloadStore: DownloadStore?

    /// Netflix-availability badges (#360). Optional so previews without the
    /// environment store still render.
    @Environment(WatchAvailabilityStore.self) private var availability: WatchAvailabilityStore?
    /// Backs the Continue Watching context-menu actions (#368) — Mark as Watched
    /// fans watched state across sources, Remove clears the server playhead.
    @Environment(AppSession.self) private var appSession

    @State private var feed: HomeFeed = .empty
    @State private var rails: UnifiedRails = .empty
    @State private var loadError: String?
    @State private var isLoading = false
    /// `true` once at least one `load()` has completed — so an empty feed during
    /// the first load or a refresh shows loading / keeps content instead of
    /// flashing the welcome / empty state.
    @State private var hasLoaded = false
    /// Guards a single automatic retry when a connected source returns an empty
    /// feed (often a transient first-load on Plex), so a transient empty
    /// self-heals instead of sticking. Reset once real content arrives.
    @State private var autoRetried = false
    /// Reload when the app returns to the foreground (non-destructive — content
    /// stays on screen through the refresh).
    @Environment(\.scenePhase) private var scenePhase
    /// Bound to the system search bar (`.searchable` modifier). When
    /// non-empty, Home swaps its rails for `MediaSearchResults`. Same
    /// search surface Library offers — both tabs let the user reach the
    /// same client-side title filter so search isn't trapped behind a
    /// dedicated tab anymore.
    @State private var searchQuery = ""
    /// iOS / visionOS: the header shows a magnifying-glass button by default and
    /// only reveals the search field once tapped — no permanent search bar.
    @State private var isSearchActive = false
    /// Owns keyboard focus so tapping outside / scrolling / selecting a result
    /// dismisses the keyboard.
    @FocusState private var searchFocused: Bool
    #if os(iOS)
    /// iPad (regular) vs iPhone (compact) — drives whether the brand + search
    /// ride the top tab-bar row (#370) or stay in the inline header.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if shouldShowBrandedChrome {
                    VStack(spacing: 0) {
                        // iPad (regular width): the wordmark + search live in the
                        // top tab-bar row as toolbar items (#370), so the idle
                        // header row is gone and the first rail rises. The search
                        // *field* still needs somewhere to land once invoked — a
                        // slim row that appears only while searching. iPhone /
                        // visionOS / tvOS keep the inline branded header.
                        #if os(iOS)
                        if usesTopBarChrome {
                            if isSearchActive { topBarSearchRow }
                        } else {
                            brandedHeader
                        }
                        #else
                        brandedHeader
                        #endif
                        content
                            .dismissSearchKeyboardOnTap { searchFocused = false }
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
            .aetherScreenBackground()
            // Pull-to-refresh on iOS/iPadOS/visionOS; tvOS uses the explicit
            // Reload button in the header (pull-to-refresh isn't available).
            #if !os(tvOS)
            .refreshable { await load(forceRefresh: true) }
            #endif
            // iPad: brand (leading) + search (trailing) flank the centered top
            // tab-bar pill instead of eating a second row (#370). iOS-only — the
            // top-bar accessory placements and the field row don't exist on the
            // other platforms, which keep the inline header.
            #if os(iOS)
            .toolbar { if usesTopBarChrome && shouldShowBrandedChrome { homeTopBarItems } }
            #endif
            .mediaNavigationDestinations(
                source: source,
                connectedSources: connectedSources,
                resumeStore: resumeStore,
                playbackSession: playbackSession,
                libraryPreferences: libraryPreferences,
                downloadManager: downloadManager,
                downloads: downloads,
                playbackPreferences: playbackPreferences
            )
        }
        // Reload when the connected set changes (sign-in / discovery / sign-out).
        .task(id: taskKey) { await load() }
        // Auto-refresh when the app returns to the foreground — keeps content on
        // screen (non-destructive) and lets a stale/empty feed self-heal without
        // a manual pull.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await load() } }
        }
    }

    /// `true` when at least one source is connected → render unified rails.
    private var usesUnified: Bool { !connectedSources.isEmpty }

    /// Stable reload key: the connected source ids (unified), else the active
    /// source id.
    private var taskKey: String {
        if usesUnified {
            return connectedSources.map { $0.id.stableKey }.sorted().joined(separator: ",")
        }
        return source?.id.stableKey ?? "none"
    }

    /// The branded header (centered Aether lockup + search field) sits
    /// above the content on the rails and during search. Loading / error /
    /// welcome / library-empty states own their full-screen layout — the
    /// header would compete with their own brand presence (the welcome
    /// surface already renders an `AetherWordmark`) and a search field is
    /// meaningless when there's nothing yet to search.
    private var shouldShowBrandedChrome: Bool {
        if isSearching { return true }
        if loadError != nil { return false }
        if isLoading && isContentEmpty { return false }
        if isContentEmpty { return false }
        return true
    }

    /// Compact nav header (0.6.0): the brand mark sits inline at the leading
    /// edge beside the search field instead of a large centered banner — far
    /// less wasted vertical space, more content density.
    private var brandedHeader: some View {
        HStack(spacing: AetherDesign.Spacing.m) {
            #if os(tvOS)
            // tvOS keeps the inline field + Reload (no pull-to-refresh, and a
            // search button would be an extra focus hop with no keyboard win).
            AetherWordmark(.medium)
            Spacer(minLength: AetherDesign.Spacing.l)
            AetherSearchField(text: $searchQuery, prompt: "Search your library", focus: $searchFocused)
                .frame(maxWidth: AetherDesign.headerSearchWidth)
            AetherTVReloadButton { Task { await load() } }
                .frame(width: 260)
            #else
            // iOS / visionOS: brand mark + a search *button*; the field only
            // appears once tapped, so the rails aren't topped by a permanent bar.
            if isSearchActive {
                AetherSearchField(text: $searchQuery, prompt: "Search your library", focus: $searchFocused)
                Button("Cancel") {
                    searchQuery = ""
                    searchFocused = false
                    isSearchActive = false
                }
                .buttonStyle(.plain)
                .foregroundStyle(AetherDesign.Palette.accent)
            } else {
                AetherWordmark(.medium)
                Spacer(minLength: AetherDesign.Spacing.l)
                searchButton
            }
            #endif
        }
        .padding(.horizontal, AetherDesign.Spacing.l)
        .padding(.top, AetherDesign.Spacing.l)
        .padding(.bottom, AetherDesign.Spacing.m)
    }

    #if !os(tvOS)
    /// Top-right magnifying-glass that reveals the search field (#header refresh).
    private var searchButton: some View {
        Button {
            isSearchActive = true
            searchFocused = true
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.title3.weight(.semibold))
                .foregroundStyle(AetherDesign.Palette.textPrimary)
                .frame(width: 44, height: 44)
                .background(AetherDesign.Palette.surface, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search")
    }
    #endif

    // MARK: - iPad top-bar chrome (#370)

    /// iPad regular width — the only place the brand + search ride the top
    /// tab-bar row as toolbar accessories. False on iPhone (compact), where the
    /// inline `brandedHeader` stays, and on visionOS / tvOS (unchanged).
    private var usesTopBarChrome: Bool {
        #if os(iOS)
        horizontalSizeClass == .regular
        #else
        false
        #endif
    }

    #if os(iOS)
    /// Brand (leading) + search (trailing) flanking the centered top tab-bar
    /// pill on iPad — replaces the second header row so content rises (#370).
    @ToolbarContentBuilder
    private var homeTopBarItems: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            AetherWordmark(.medium)
        }
        // iOS 26 wraps toolbar items in a circular "Liquid Glass" background,
        // which clipped the wide (~3:2) wordmark into a broken disc. Hide the
        // shared background so the lockup renders flush, like a brand mark and
        // not a button. (The search glyph below keeps its glass — an icon reads
        // fine as a circular control.)
        .sharedBackgroundVisibility(.hidden)
        // While searching, the field + Cancel own the slim row below; the
        // trailing glyph would be redundant, so it hides until search dismisses.
        if !isSearchActive {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isSearchActive = true
                    searchFocused = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("Search")
            }
        }
    }

    /// The search field revealed on iPad once the toolbar search button is
    /// tapped — a slim row above the rails (no permanent search bar), dismissed
    /// by Cancel. Mirrors the inline field used on iPhone.
    private var topBarSearchRow: some View {
        HStack(spacing: AetherDesign.Spacing.m) {
            AetherSearchField(text: $searchQuery, prompt: "Search your library", focus: $searchFocused)
            Button("Cancel") {
                searchQuery = ""
                searchFocused = false
                isSearchActive = false
            }
            .buttonStyle(.plain)
            .foregroundStyle(AetherDesign.Palette.accent)
        }
        .padding(.horizontal, AetherDesign.Spacing.l)
        .padding(.top, AetherDesign.Spacing.s)
        .padding(.bottom, AetherDesign.Spacing.m)
    }
    #endif

    /// True when the user is searching from Home. Drives the swap from
    /// rails to results — same behaviour Library has.
    private var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var content: some View {
        if isSearching {
            // Unified search across every connected source.
            MediaSearchResults(sources: connectedSources, query: searchQuery)
        } else if let loadError {
            AetherCenteredScrollState { errorState(loadError) }
        } else if !isContentEmpty {
            // Have content → always show it, even while a refresh is running, so
            // pull-to-refresh never blanks to a loading/empty/welcome state.
            if usesUnified { unifiedRailsContent } else { railsContent }
        } else if isConnecting || isLoading || !hasLoaded {
            // Still starting up, loading, or the first load hasn't finished —
            // show the branded loading animation rather than flashing
            // "connect Plex" / "empty". Centered + pull-to-refreshable.
            AetherCenteredScrollState { loadingState }
        } else {
            // Signed-out welcome owns its own full-screen layout; the connected
            // empty states are centered + pull-to-refreshable so they never
            // render as a band and can be re-pulled if they were transient.
            if isPlexSignedIn || usesUnified {
                AetherCenteredScrollState { emptyState }
            } else {
                emptyState
            }
        }
    }

    /// Whether the visible feed has nothing to show (unified or single-source).
    private var isContentEmpty: Bool {
        if usesUnified { return rails.isEmpty }
        return feedIsEmpty
    }

    // MARK: - Unified rails (deduplicated across all connected sources)

    /// Home is the **watch-now** surface: what to resume, what's new, what's
    /// offline. The full deduplicated catalog (Movies / TV Shows browsing) lives
    /// in the Library tab — Home doesn't repeat it.
    private var unifiedRailsContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                if !rails.continueWatching.isEmpty {
                    continueWatchingSection
                }
                let recentlyAdded = discoveryFiltered(rails.recentlyAdded)
                if !recentlyAdded.isEmpty {
                    unifiedSection(title: "Recently Added", items: recentlyAdded)
                }
                let recentlyReleased = discoveryFiltered(rails.recentlyReleased)
                if !recentlyReleased.isEmpty {
                    unifiedSection(title: "Recently Released", items: recentlyReleased)
                }
                if !rails.downloaded.isEmpty {
                    unifiedSection(title: "Downloaded", items: rails.downloaded)
                }
            }
            .padding(.bottom, AetherDesign.Spacing.xxl)
        }
    }

    /// Home is what's *ahead*: with the (default-on) hide-watched preference,
    /// fully-watched titles drop out of the discovery rails. The Library keeps
    /// the complete catalog; Continue Watching / Downloaded are never filtered.
    private func discoveryFiltered(_ items: [UnifiedMediaItem]) -> [UnifiedMediaItem] {
        guard playbackPreferences?.hideWatchedInDiscovery ?? true else { return items }
        return items.filter { !$0.isFullyWatched }
    }

    /// A horizontal poster rail of **unified** titles. Each card navigates the
    /// `UnifiedMediaItem` itself (not a per-source `MediaItem`), so Detail gets
    /// the full source list for its "Available Sources" section.
    private func unifiedSection(title: String, items: [UnifiedMediaItem]) -> some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            AetherSectionHeader(title: title)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: AetherDesign.Spacing.l) {
                    ForEach(items) { unified in
                        NavigationLink(value: unified) {
                            AetherCard.poster(title: unified.title, posterURL: unified.posterURL, isWatched: unified.isFullyWatched, netflixLogoURL: availability?.netflixLogoURL(for: unified))
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

    // MARK: - Rails

    /// Rails order: **Continue Watching** first when present, then
    /// Featured, then a section per library. The active-content-first
    /// pattern matches Netflix / Apple TV / Disney+ — the user's
    /// in-progress titles take priority over the discovery rail because
    /// resuming is the most common reason a returning user lands on
    /// Home. Featured stays prominent (second slot, hero artwork)
    /// rather than getting pushed below library sections.
    private var railsContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                if !feed.continueWatching.isEmpty {
                    continueWatchingSection
                }

                if !feed.featured.isEmpty {
                    featuredSection
                }

                ForEach(feed.libraries) { librarySection in
                    section(
                        title: librarySection.library.title,
                        items: librarySection.items,
                        library: librarySection.library
                    )
                }
            }
            .padding(.bottom, AetherDesign.Spacing.xxl)
        }
    }

    // MARK: - Section (generic horizontal poster rail)

    private var posterWidth: CGFloat {
        #if os(tvOS)
        300
        #else
        168
        #endif
    }

    /// Generic horizontal poster rail. When `library` is non-nil the header
    /// gains a "See all" accessory that pushes the full grid.
    private func section(
        title: String,
        items: [MediaItem],
        library: Library? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            AetherSectionHeader(
                title: title,
                accessoryTitle: library != nil ? "See all" : nil,
                // Explicit return type so the closure inherits `@MainActor`
                // isolation (Swift 6 strict concurrency).
                accessoryAction: library.map { lib -> @MainActor () -> Void in
                    { navigationPath.append(lib) }
                }
            )

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: AetherDesign.Spacing.l) {
                    ForEach(items) { item in
                        NavigationLink(value: item) {
                            AetherCard.poster(title: item.title, posterURL: item.posterURL, isWatched: item.isFullyWatched, netflixLogoURL: availability?.netflixLogoURL(for: item))
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

    // MARK: - Featured (hero-sized 16:9 cards)

    private var featuredSection: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            AetherSectionHeader(title: "Featured")

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: AetherDesign.Spacing.l) {
                    ForEach(feed.featured) { item in
                        NavigationLink(value: item) {
                            AetherCard.hero(
                                title: item.title,
                                subtitle: item.year.map(String.init),
                                posterURL: item.backdropURL ?? item.posterURL
                            )
                            .frame(width: featuredCardWidth)
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

    private var featuredCardWidth: CGFloat {
        #if os(tvOS)
        560
        #else
        320
        #endif
    }

    // MARK: - Continue Watching (carries progress overlay)

    private var continueWatchingSection: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            // Subtitle doubles as the discoverability hint for the in-place
            // context menu (#368) — users won't find a long-press affordance
            // without a cue.
            AetherSectionHeader(title: "Continue Watching", subtitle: "Pick up where you left off · hold to remove")

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: AetherDesign.Spacing.l) {
                    ForEach(feed.continueWatching) { entry in
                        NavigationLink(value: entry.item) {
                            AetherCard.episode(
                                title: DetailFormatting.continueWatchingLabel(entry.item),
                                thumbURL: entry.item.backdropURL ?? entry.item.posterURL,
                                progress: entry.progress
                            )
                            .frame(width: episodeCardWidth)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { continueWatchingMenu(for: entry) }
                    }
                }
                .padding(.horizontal, AetherDesign.Spacing.l)
                .padding(.vertical, AetherDesign.Spacing.xs)
            }
            .aetherFocusSection()
        }
    }

    private var episodeCardWidth: CGFloat {
        #if os(tvOS)
        480
        #else
        296
        #endif
    }

    /// In-place actions on a Continue Watching card (#368), so a stale entry can
    /// leave the top rail without a trip into Detail. Long-press on iOS/iPadOS,
    /// the focused-card menu on tvOS, right-click on Catalyst — all native
    /// `.contextMenu` surfaces.
    @ViewBuilder
    private func continueWatchingMenu(for entry: HomeFeed.ContinueWatchingEntry) -> some View {
        Button {
            Task { await markEntryWatched(entry) }
        } label: {
            Label("Mark as Watched", systemImage: "checkmark.circle")
        }
        Button(role: .destructive) {
            Task { await removeFromContinueWatching(entry) }
        } label: {
            Label("Remove from Continue Watching", systemImage: "minus.circle")
        }
    }

    /// Mark watched across every source that has the title, drop its resume
    /// point, and refresh the rail in place.
    private func markEntryWatched(_ entry: HomeFeed.ContinueWatchingEntry) async {
        await appSession.markWatchedEverywhere(entry.item, watched: true)
        await resumeStore.clear(for: entry.item.id)
        await load()
    }

    /// Remove the title from Continue Watching **without** marking it watched:
    /// zero the server playhead (so it leaves Plex On Deck / Jellyfin Resume and
    /// won't re-seed), clear the local resume point, then refresh. A non-forced
    /// `load()` rebuilds the rail from the now-cleared store without re-seeding.
    private func removeFromContinueWatching(_ entry: HomeFeed.ContinueWatchingEntry) async {
        await appSession.clearContinueWatchingEverywhere(entry.item)
        await resumeStore.clear(for: entry.item.id)
        await load()
    }

    // MARK: - Empty / welcome states

    private var feedIsEmpty: Bool {
        feed.featured.isEmpty
            && feed.continueWatching.isEmpty
            && feed.libraries.allSatisfy { $0.items.isEmpty }
    }

    private var isDiscoveryInFlight: Bool {
        if case .discovering = plexDiscoveryState { return true }
        if case .idle = plexDiscoveryState, isPlexSignedIn, plexServerName == nil { return true }
        return false
    }

    /// Not signed in → cinematic welcome. Signed in but no content → an honest,
    /// friendly state (looking / none found / failed / connected-but-empty).
    @ViewBuilder
    private var emptyState: some View {
        if !isPlexSignedIn {
            WelcomeView(onAddSource: onAddSource)
        } else {
            AetherEmptyState(
                glyph: emptyStateGlyph,
                title: emptyStateTitle,
                message: emptyStateBody,
                action: emptyStateAction
            )
        }
    }

    private var emptyStateGlyph: String {
        if plexServerName != nil { return "checkmark.seal" }
        switch plexDiscoveryState {
        case .noServersFound:        return "magnifyingglass"
        case .failed:                return "exclamationmark.triangle"
        case .idle, .discovering, .completed: return "antenna.radiowaves.left.and.right"
        }
    }

    private var emptyStateTitle: String {
        if let plexServerName { return "Connected to \(plexServerName)" }
        switch plexDiscoveryState {
        case .noServersFound: return "No servers found"
        case .failed:         return "Couldn't reach Plex"
        case .idle, .discovering, .completed: return "Looking for your servers"
        }
    }

    private var emptyStateBody: String {
        if let plexServerName {
            return "\(plexServerName) doesn't have any movie or show libraries Aether can read yet. Add one in Plex, then refresh."
        }
        switch plexDiscoveryState {
        case .noServersFound:
            return "Your Plex account isn't connected to any reachable servers right now. Check that your server is powered on and signed in to the same account."
        case let .failed(message):
            return message
        case .idle, .discovering, .completed:
            return "Asking Plex which servers your account can reach…"
        }
    }

    private var emptyStateAction: AetherEmptyState.Action? {
        switch plexDiscoveryState {
        case .noServersFound, .failed:
            return .init(label: "Try again", run: onRetryDiscovery)
        case .idle, .discovering, .completed:
            return nil
        }
    }

    // MARK: - Loading & error states

    private var loadingState: some View {
        AetherLoadingDots(caption: "Loading your library…")
    }

    private func errorState(_ message: String) -> some View {
        AetherErrorState(
            title: "Couldn't reach your server",
            message: message,
            retry: .init { Task { await reconnectAndLoad() } }
        )
    }

    /// Drop any cached connection and reload — so a retry after moving networks
    /// (LAN → cellular) re-probes instead of reusing a now-dead connection.
    private func reconnectAndLoad() async {
        if let plex = source as? PlexMediaSource {
            await plex.invalidateConnection()
        }
        await load()
    }

    // MARK: - Loading

    private func load(forceRefresh: Bool = false) async {
        loadError = nil
        defer { hasLoaded = true }

        // Unified path: aggregate + dedupe across every connected source. The
        // aggregator is fault-tolerant (no throw) — a down server is skipped.
        if usesUnified {
            isLoading = true
            defer { isLoading = false }
            let library = UnifiedLibrary(sources: connectedSources, downloads: downloadStore)
            let built = await library.homeRails(resumeStore: resumeStore, forceRefresh: forceRefresh)
            if built.isEmpty, !rails.isEmpty {
                // A refresh came back empty but we already have content on screen —
                // almost always a transient source hiccup (a server that briefly
                // returns no libraries). Keep what's showing instead of blanking
                // it to an empty state, and retry once.
                scheduleAutoRetryIfNeeded()
            } else {
                rails = built
                // Mirror Continue Watching into `feed` so the shared section renders.
                feed = HomeFeed(featured: [], continueWatching: built.continueWatching, libraries: [])
                if built.isEmpty { scheduleAutoRetryIfNeeded() } else { autoRetried = false }
            }
            // Warm the artwork cache for the rails we're about to show.
            AetherImageCache.shared.prefetch(
                built.recentlyAdded.map(\.posterURL)
                    + built.recentlyReleased.map(\.posterURL)
                    + built.downloaded.map(\.posterURL)
                    + built.continueWatching.map { $0.item.backdropURL ?? $0.item.posterURL }
            )
            // Stale-while-revalidate (#197): the catalog we just painted may be a
            // persisted snapshot served instantly on a cold launch. If it's past
            // the 1-hour window, refresh silently in the background — content
            // stays on screen (the spinner only shows over an empty view).
            if !forceRefresh, !built.isEmpty {
                let staleMovies = await library.isStale(kind: .movie)
                let staleShows = await library.isStale(kind: .show)
                if staleMovies || staleShows { Task { await load(forceRefresh: true) } }
            }
            return
        }

        // Single-source fallback (not connected → welcome/empty states).
        guard let source else {
            feed = .empty
            rails = .empty
            isLoading = false
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

    /// One automatic retry when a connected source returns an empty feed — Plex
    /// often returns nothing on the very first request after connecting, which
    /// otherwise leaves the user stuck on an empty state. Bounded to a single
    /// attempt (guarded by `autoRetried`); manual pull-to-refresh and the
    /// foreground reload cover anything beyond that.
    private func scheduleAutoRetryIfNeeded() {
        guard !autoRetried, !connectedSources.isEmpty else { return }
        autoRetried = true
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, isContentEmpty else { return }
            await load(forceRefresh: true)
        }
    }
}

/// The signed-out hero: a calm radial glow behind a large title, one line of
/// plain-language copy, and a single primary action. No tables, no jargon.
private struct WelcomeView: View {
    let onAddSource: () -> Void

    var body: some View {
        ZStack {
            AetherDesign.Gradients.heroBloom
                .ignoresSafeArea()

            VStack(spacing: AetherDesign.Spacing.l) {
                // The wordmark IS the welcome — first surface where the user
                // meets the brand inside the app, so the mark takes the hero
                // slot. A single actionable line + CTA support it underneath.
                AetherWordmark(.large)

                Text("Connect a Plex or Synology source to begin.")
                    .font(AetherDesign.Typography.body)
                    .foregroundStyle(AetherDesign.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                AetherButton("Add a source", systemImage: "plus", action: onAddSource)
                    .padding(.top, AetherDesign.Spacing.s)
            }
            .frame(maxWidth: 560)
            .padding(AetherDesign.Spacing.xl)
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

    /// Tap-to-dismiss the search keyboard — iOS / visionOS only. On tvOS there's
    /// no software keyboard, and a `TapGesture` there would intercept the Select
    /// button and disrupt the focus engine, so it's a no-op.
    @ViewBuilder
    func dismissSearchKeyboardOnTap(_ action: @escaping () -> Void) -> some View {
        #if os(iOS) || os(visionOS)
        simultaneousGesture(TapGesture().onEnded(action))
        #else
        self
        #endif
    }
}
