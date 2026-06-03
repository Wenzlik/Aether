import SwiftUI
import AetherCore

/// The Home tab — cinematic, content-first. No page chrome: the tab bar above
/// already says "Home", so the screen opens straight into artwork (Featured,
/// Continue Watching, then a rail per library). When no source is connected it
/// shows a welcoming hero instead of a utility dashboard.
struct HomeView: View {
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

    @State private var feed: HomeFeed = .empty
    @State private var loadError: String?
    @State private var isLoading = false
    /// Drives the `NavigationStack` so a library rail's "See all" accessory can
    /// push `LibraryView`. Card taps push onto the same path via `NavigationLink`.
    @State private var navigationPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navigationPath) {
            content
                .background(AetherDesign.Gradients.background.ignoresSafeArea())
                .mediaNavigationDestinations(
                    source: source,
                    resumeStore: resumeStore,
                    playbackSession: playbackSession,
                    libraryPreferences: libraryPreferences
                )
        }
        // Reload whenever the source changes (nil → Plex after discovery, or
        // Plex → nil on sign-out). Without id:, .task fires once.
        .task(id: source?.id) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let loadError {
            errorState(loadError)
        } else if isLoading && feed == .empty {
            loadingState
        } else if feedIsEmpty {
            emptyState
        } else {
            railsContent
        }
    }

    // MARK: - Rails

    private var railsContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                if !feed.featured.isEmpty {
                    featuredSection
                }

                if !feed.continueWatching.isEmpty {
                    continueWatchingSection
                }

                ForEach(feed.libraries) { librarySection in
                    section(
                        title: librarySection.library.title,
                        items: librarySection.items,
                        library: librarySection.library
                    )
                }
            }
            .padding(.top, AetherDesign.Spacing.l)
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

    private var episodeCardWidth: CGFloat {
        #if os(tvOS)
        480
        #else
        296
        #endif
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
        AetherLoadingState(.rails(count: 2))
            .padding(.top, AetherDesign.Spacing.l)
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
                // slot. The tagline + CTA support it underneath.
                AetherWordmark(.large)

                Text("Your media, beautifully organized. Connect a Plex or Synology source to begin.")
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
}
