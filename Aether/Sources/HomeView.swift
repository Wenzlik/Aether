import SwiftUI
import AetherCore

struct HomeView: View {
    /// `nil` when no source is configured yet — Home shows its welcome / empty
    /// state in that case (no mock fallback).
    let source: (any MediaSource)?
    let resumeStore: ResumeStore
    let playbackSession: PlaybackSession
    let isPlexSignedIn: Bool
    let plexServerName: String?
    let plexDiscoveryState: AppSession.DiscoveryState
    let onAddSource: () -> Void
    let onRetryDiscovery: () -> Void
    let onOpenSettings: () -> Void

    @State private var feed: HomeFeed = .empty
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var selectedSurface: HomeSurface = .home

    /// Initial focus target for tvOS. Without this the focus engine picks the
    /// first focusable element below the fold (typically a poster card in the
    /// featured rail) and scrolls the page to make it visible — which on cold
    /// launch hides the top tab capsule. `.defaultFocus` on the top-tab HStack
    /// points the engine at the Home tab instead. iOS / iPadOS / visionOS
    /// don't use the focus engine the same way, but the state declaration is
    /// harmless on those platforms.
    @FocusState private var focusedTopTab: HomeSurface?

    var body: some View {
        NavigationStack {
            #if os(tvOS)
            // tvOS: keep the header outside the ScrollView so the top-tab
            // capsule never scrolls offscreen. `.defaultFocus` alone wasn't
            // enough — the focus engine still landed on a card buried in the
            // featured rail on cold launch, scrolled the page to make it
            // visible, and the chrome went out of view. Pinning the header
            // above the scroll content prevents that scroll from hiding it.
            VStack(spacing: 0) {
                header
                    .padding(.vertical, AetherDesign.Spacing.l)
                scrollableContent
            }
            .background(AetherDesign.Palette.background.ignoresSafeArea())
            .navigationDestination(for: MediaItem.self) { item in
                DetailView(
                    item: item,
                    source: source,
                    resumeStore: resumeStore,
                    playbackSession: playbackSession
                )
            }
            // Belt-and-suspenders for the focus engine: explicitly send
            // focus to the Home top tab on first appear. `.defaultFocus` is
            // declarative and can lose the race against initial layout; this
            // imperative assignment is the safety net.
            .task {
                if focusedTopTab == nil {
                    focusedTopTab = .home
                }
            }
            #else
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                    header
                    selectedContent
                }
                .padding(.vertical, AetherDesign.Spacing.l)
                .padding(.bottom, bottomContentInset)
            }
            .background(AetherDesign.Palette.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) { bottomDock }
            .navigationDestination(for: MediaItem.self) { item in
                DetailView(
                    item: item,
                    source: source,
                    resumeStore: resumeStore,
                    playbackSession: playbackSession
                )
            }
            #endif
        }
        // Re-run load() whenever the underlying source changes (nil → Plex
        // after AppSession.start() finishes discovery, or Plex → nil on
        // sign-out). Without the id:, .task fires once on first appear.
        .task(id: source?.id) { await load() }
    }

    /// The scrollable body — used by the tvOS branch where the header lives
    /// outside the ScrollView. iOS / iPadOS / visionOS still render the
    /// header inside the same scrollable LazyVStack above (it scrolls away
    /// with content, which is the standard mobile pattern).
    #if os(tvOS)
    private var scrollableContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                selectedContent
            }
            .padding(.bottom, AetherDesign.Spacing.xxl)
        }
    }
    #endif

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: AetherDesign.Spacing.m) {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
                Text(selectedSurface.title)
                    .font(AetherDesign.Typography.heroTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                Text(headerSubtitle)
                    .font(AetherDesign.Typography.metadata)
                    .foregroundStyle(AetherDesign.Palette.textSecondary)
            }

            Spacer(minLength: AetherDesign.Spacing.m)

            topChrome
        }
        .padding(.horizontal, AetherDesign.Spacing.l)
    }

    private var headerSubtitle: String {
        switch selectedSurface {
        case .home:
            if let plexServerName { return "Aether on \(plexServerName)" }
            if isDiscoveryInFlight { return "Finding your Plex servers..." }
            if isPlexSignedIn { return "Ready to connect your library." }
            return "Personal media, beautifully played."
        case .files:
            return "Sources, servers, and local media."
        case .search:
            return "Find titles across your library."
        }
    }

    private var topChrome: some View {
        HStack(spacing: AetherDesign.Spacing.s) {
            #if os(tvOS)
            HStack(spacing: AetherDesign.Spacing.xs) {
                TopTabButton(surface: .home, isSelected: selectedSurface == .home) {
                    selectedSurface = .home
                }
                .focused($focusedTopTab, equals: .home)

                TopTabButton(surface: .files, isSelected: selectedSurface == .files) {
                    selectedSurface = .files
                }
                .focused($focusedTopTab, equals: .files)

                TopTabButton(surface: .search, isSelected: selectedSurface == .search) {
                    selectedSurface = .search
                }
                .focused($focusedTopTab, equals: .search)
            }
            .padding(AetherDesign.Spacing.xxs)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule().stroke(AetherDesign.Palette.separator, lineWidth: 1)
            }
            // Tell tvOS's focus engine: this is where to start. Without it,
            // the engine picks the first card below and scrolls to it,
            // hiding the chrome on cold launch.
            .defaultFocus($focusedTopTab, .home)
            #endif

            HStack(spacing: AetherDesign.Spacing.xxs) {
                // Always-visible source button so sign-in remains reachable
                // even when Home is full of content.
                Button(action: onAddSource) {
                    HeaderIcon(
                        glyph: accountGlyph,
                        isActive: plexServerName != nil
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accountAccessibilityLabel)

                if isPlexSignedIn {
                    Button(action: onRetryDiscovery) {
                        HeaderIcon(glyph: "arrow.clockwise", isActive: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Refresh sources")
                }

                #if os(tvOS)
                Button(action: onOpenSettings) {
                    HeaderIcon(glyph: "gearshape", isActive: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
                #endif
            }
            .padding(AetherDesign.Spacing.xxs)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule().stroke(AetherDesign.Palette.separator, lineWidth: 1)
            }
        }
    }

    private var accountGlyph: String {
        if plexServerName != nil { return "person.crop.circle.fill" }
        if isPlexSignedIn        { return "person.crop.circle" }
        return "person.crop.circle.badge.plus"
    }

    private var accountAccessibilityLabel: String {
        if let name = plexServerName { return "Connected to \(name). Account details." }
        if isPlexSignedIn            { return "Signed in to Plex. Account details." }
        return "Add a source"
    }

    // MARK: - Surfaces

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedSurface {
        case .home:
            homeContent
        case .files:
            filesContent
        case .search:
            searchContent
        }
    }

    @ViewBuilder
    private var homeContent: some View {
        if let loadError {
            errorState(loadError)
        } else if isLoading && feed == .empty {
            loadingState
        } else if feedIsEmpty {
            emptyLibraryState
        } else {
            if !feed.featured.isEmpty {
                featuredSection
            }

            if !feed.continueWatching.isEmpty {
                continueWatchingSection
            }

            ForEach(feed.libraries) { librarySection in
                // Both movie and show libraries surface posters at the top
                // level. Episode aspect (16:9) is for the show -> seasons ->
                // episodes drill-down.
                section(
                    title: librarySection.library.title,
                    items: librarySection.items,
                    aspect: .poster
                )
            }
        }
    }

    private var filesContent: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            AetherSectionHeader(
                title: "Sources",
                subtitle: "Your connected media locations"
            )

            LazyVGrid(columns: sourceColumns, spacing: AetherDesign.Spacing.m) {
                SourceTile(
                    title: "Plex",
                    subtitle: plexSourceSubtitle,
                    glyph: "play.rectangle",
                    isActive: plexServerName != nil,
                    action: onAddSource
                )

                SourceTile(
                    title: "Synology",
                    subtitle: "Coming soon",
                    glyph: "server.rack",
                    isActive: false,
                    action: nil
                )

                SourceTile(
                    title: "Offline",
                    subtitle: "Coming soon",
                    glyph: "arrow.down.circle",
                    isActive: false,
                    action: nil
                )
            }
            .padding(.horizontal, AetherDesign.Spacing.l)
        }
    }

    private var searchContent: some View {
        AetherEmptyState(
            glyph: "magnifyingglass",
            title: "Search",
            message: "Search will become useful once local indexing lands."
        )
    }

    private var plexSourceSubtitle: String {
        if let plexServerName { return plexServerName }
        if isDiscoveryInFlight { return "Finding servers" }
        if isPlexSignedIn { return "Signed in" }
        return "Not connected"
    }

    private var sourceColumns: [GridItem] {
        #if os(tvOS)
        [GridItem(.adaptive(minimum: 320, maximum: 420), spacing: AetherDesign.Spacing.l)]
        #else
        [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: AetherDesign.Spacing.m)]
        #endif
    }

    private var bottomContentInset: CGFloat {
        #if os(tvOS)
        0
        #else
        104
        #endif
    }

    @ViewBuilder
    private var bottomDock: some View {
        #if os(tvOS)
        EmptyView()
        #else
        HomeBottomDock(
            selectedSurface: selectedSurface,
            onSelect: { selectedSurface = $0 },
            onOpenSettings: onOpenSettings
        )
        .padding(.horizontal, AetherDesign.Spacing.l)
        .padding(.bottom, AetherDesign.Spacing.s)
        #endif
    }

    // MARK: - Section (generic horizontal rail)

    private enum CardAspect {
        case poster
        case episode

        var ratio: CGFloat {
            switch self {
            case .poster: return 2.0 / 3.0
            case .episode: return 16.0 / 9.0
            }
        }

        var width: CGFloat {
            #if os(tvOS)
            // Couch distance — cards need real estate to read. See DESIGN_PRINCIPLES.md.
            switch self {
            case .poster: return 300
            case .episode: return 480
            }
            #else
            switch self {
            case .poster: return 168
            case .episode: return 296
            }
            #endif
        }
    }

    private func section(title: String, items: [MediaItem], aspect: CardAspect) -> some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            AetherSectionHeader(title: title)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: AetherDesign.Spacing.l) {
                    ForEach(items) { item in
                        NavigationLink(value: item) {
                            AetherCard.poster(
                                title: item.title,
                                posterURL: item.posterURL
                            )
                            .frame(width: aspect.width)
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

    // MARK: - Featured section (hero-sized 16:9 cards)

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

    // MARK: - Continue Watching section (carries progress overlay)

    private var continueWatchingSection: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            AetherSectionHeader(title: "Continue Watching", subtitle: "Pick up where you left off")

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: AetherDesign.Spacing.l) {
                    ForEach(feed.continueWatching) { entry in
                        NavigationLink(value: entry.item) {
                            AetherCard.episode(
                                title: entry.item.title,
                                thumbURL: entry.item.backdropURL ?? entry.item.posterURL,
                                progress: entry.progress
                            )
                            .frame(width: CardAspect.episode.width)
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

    // MARK: - Empty state

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

    private var emptyStateGlyph: String {
        if plexServerName != nil { return "checkmark.seal" }
        if isPlexSignedIn {
            switch plexDiscoveryState {
            case .noServersFound:        return "magnifyingglass"
            case .failed:                return "exclamationmark.triangle"
            case .idle, .discovering, .completed: return "antenna.radiowaves.left.and.right"
            }
        }
        return "film.stack"
    }

    private var emptyStateTitle: String {
        if let plexServerName { return "Connected to \(plexServerName)" }
        if isPlexSignedIn {
            switch plexDiscoveryState {
            case .noServersFound: return "No servers found"
            case .failed:         return "Couldn't reach Plex"
            case .idle, .discovering, .completed: return "Looking for your servers"
            }
        }
        return "Your library is empty"
    }

    private var emptyStateBody: String {
        if let plexServerName {
            // Connected, but the server has no movie or show libraries that
            // Aether knows how to render (music + photos are skipped in 0.2).
            return "\(plexServerName) doesn't have any movie or show libraries Aether can read yet. Add one in Plex and pull to refresh."
        }
        if isPlexSignedIn {
            switch plexDiscoveryState {
            case .noServersFound:
                return "Your Plex account isn't connected to any reachable servers right now. Check that your server is powered on and signed in to the same account."
            case let .failed(message):
                return message
            case .idle, .discovering, .completed:
                return "Asking Plex which servers your account can reach…"
            }
        }
        return "Connect a Plex or Synology source to start watching."
    }

    private var emptyLibraryState: some View {
        AetherEmptyState(
            glyph: emptyStateGlyph,
            title: emptyStateTitle,
            message: emptyStateBody,
            action: emptyStateAction
        )
    }

    private var emptyStateAction: AetherEmptyState.Action? {
        if !isPlexSignedIn {
            return .init(label: "Add a source", run: onAddSource)
        }
        if case .noServersFound = plexDiscoveryState {
            return .init(label: "Try again", run: onRetryDiscovery)
        }
        if case .failed = plexDiscoveryState {
            return .init(label: "Try again", run: onRetryDiscovery)
        }
        // .discovering / .idle / .completed → no CTA
        return nil
    }

    // MARK: - Loading & error states

    private var loadingState: some View {
        AetherLoadingState(.rails(count: 2))
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

    private func load() async {
        loadError = nil

        // No source yet (not signed in, or discovery in flight): clear the feed
        // and let the welcome / empty state render. Don't show the skeleton.
        guard let source else {
            feed = .empty
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
}

private enum HomeSurface {
    case home
    case files
    case search

    var title: String {
        switch self {
        case .home: return "Home"
        case .files: return "Files"
        case .search: return "Search"
        }
    }
}

/// Header icon used in the compact source/refresh chrome.
private struct HeaderIcon: View {
    let glyph: String
    let isActive: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Image(systemName: glyph)
            #if os(tvOS)
            .font(.system(size: 36, weight: .regular))
            #else
            .font(.system(size: 22, weight: .regular))
            #endif
            .foregroundStyle(isActive ? AetherDesign.Palette.accent : AetherDesign.Palette.textPrimary)
            .frame(width: 48, height: 48)
            .shadow(color: .black.opacity(isFocused ? 0.45 : 0.0),
                    radius: isFocused ? 14 : 0,
                    y: isFocused ? 8 : 0)
            .scaleEffect(isFocused ? 1.10 : 1.0)
            .animation(AetherDesign.Motion.focus, value: isFocused)
    }
}

private struct TopTabButton: View {
    let surface: HomeSurface
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Button(action: action) {
            Text(surface.title)
                .font(AetherDesign.Typography.cardTitle)
                .padding(.horizontal, AetherDesign.Spacing.l)
                .padding(.vertical, AetherDesign.Spacing.s)
                .background(
                    Capsule()
                        .fill(isSelected ? AetherDesign.Palette.accent.opacity(isFocused ? 0.45 : 0.22) : AetherDesign.Palette.surface.opacity(isFocused ? 1.0 : 0.0))
                )
                .foregroundStyle(isSelected ? AetherDesign.Palette.textPrimary : AetherDesign.Palette.textSecondary)
                .scaleEffect(isFocused ? 1.05 : 1.0)
                .animation(AetherDesign.Motion.focus, value: isFocused)
        }
        .buttonStyle(.plain)
    }
}

private struct HomeBottomDock: View {
    let selectedSurface: HomeSurface
    let onSelect: (HomeSurface) -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: AetherDesign.Spacing.s) {
            HStack(spacing: AetherDesign.Spacing.xxs) {
                dockButton(surface: .home, glyph: "play")
                dockButton(surface: .files, glyph: "folder")
                Button(action: onOpenSettings) {
                    dockIcon(glyph: "gearshape", isSelected: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }
            .padding(AetherDesign.Spacing.xxs)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule().stroke(AetherDesign.Palette.separator, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.35), radius: 24, y: 12)

            Button {
                onSelect(.search)
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(selectedSurface == .search ? AetherDesign.Palette.accent : AetherDesign.Palette.textPrimary)
                    .frame(width: 62, height: 62)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay {
                        Circle().stroke(AetherDesign.Palette.separator, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search")
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }

    private func dockButton(surface: HomeSurface, glyph: String) -> some View {
        Button {
            onSelect(surface)
        } label: {
            dockIcon(glyph: glyph, isSelected: selectedSurface == surface)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(surface.title)
    }

    private func dockIcon(glyph: String, isSelected: Bool) -> some View {
        Image(systemName: glyph)
            .font(.system(size: 26, weight: .medium))
            .foregroundStyle(isSelected ? AetherDesign.Palette.accent : AetherDesign.Palette.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background {
                if isSelected {
                    Capsule()
                        .fill(AetherDesign.Palette.surfaceElevated.opacity(0.92))
                }
            }
            .contentShape(Capsule())
    }
}

private struct SourceTile: View {
    let title: String
    let subtitle: String
    let glyph: String
    let isActive: Bool
    let action: (() -> Void)?

    var body: some View {
        Group {
            if let action {
                Button(action: action) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.s) {
            ZStack {
                RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                    .fill(tileFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                            .stroke(AetherDesign.Palette.separator, lineWidth: 1)
                    }

                Image(systemName: glyph)
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(isActive ? AetherDesign.Palette.accent : AetherDesign.Palette.textTertiary)
            }
            .aspectRatio(1, contentMode: .fit)

            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xxs) {
                Text(title)
                    .font(AetherDesign.Typography.cardTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(AetherDesign.Typography.caption)
                    .foregroundStyle(AetherDesign.Palette.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private var tileFill: some ShapeStyle {
        if isActive {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        AetherDesign.Palette.accent.opacity(0.28),
                        AetherDesign.Palette.surfaceElevated
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        return AnyShapeStyle(AetherDesign.Palette.surface)
    }
}

private extension View {
    /// Apply `.focusSection()` on tvOS, no-op elsewhere.
    ///
    /// SwiftUI's `focusSection()` is tvOS-only — calling it on iOS produces an
    /// `'focusSection()' is unavailable in iOS` error. The Home rails want it
    /// on tvOS for predictable D-pad behaviour between rails, but the code
    /// itself is the same on both platforms, so we hide the platform check in
    /// this small extension.
    @ViewBuilder
    func aetherFocusSection() -> some View {
        #if os(tvOS)
        self.focusSection()
        #else
        self
        #endif
    }
}
