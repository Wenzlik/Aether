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

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                    header

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
                            // Both movie and show libraries surface posters at
                            // the top level (a show's top-level artwork is its
                            // poster, not an episode still). Episode aspect
                            // (16:9) is for the future show → seasons →
                            // episodes drill-down.
                            section(
                                title: librarySection.library.title,
                                items: librarySection.items,
                                aspect: .poster
                            )
                        }
                    }
                }
                .padding(.vertical, AetherDesign.Spacing.l)
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
        }
        // Re-run load() whenever the underlying source changes (nil → Plex
        // after AppSession.start() finishes discovery, or Plex → nil on
        // sign-out). Without the id:, .task fires once on first appear.
        .task(id: source?.id) { await load() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: AetherDesign.Spacing.m) {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
                Text("Aether")
                    .font(AetherDesign.Typography.heroTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                Text("Personal media, beautifully played.")
                    .font(AetherDesign.Typography.metadata)
                    .foregroundStyle(AetherDesign.Palette.textSecondary)
            }

            Spacer(minLength: AetherDesign.Spacing.m)

            HStack(spacing: AetherDesign.Spacing.s) {
                // Always-visible account / source button so the sign-in flow is
                // reachable even when the library has plenty of content (which
                // hides the empty state CTA).
                Button(action: onAddSource) {
                    AccountBadge(
                        glyph: accountGlyph,
                        isActive: plexServerName != nil
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accountAccessibilityLabel)

                Button(action: onOpenSettings) {
                    AccountBadge(glyph: "gearshape", isActive: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }
        }
        .padding(.horizontal, AetherDesign.Spacing.l)
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

/// Account / source button glyph used in the Home header.
///
/// Pulled out so it can react to the tvOS focus environment without complicating
/// the parent layout. On iOS `\.isFocused` is always false, so the focused
/// branch collapses to the base styling.
private struct AccountBadge: View {
    let glyph: String
    let isActive: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Image(systemName: glyph)
            #if os(tvOS)
            .font(.system(size: 36, weight: .regular))
            #else
            .font(.system(size: 28, weight: .regular))
            #endif
            .foregroundStyle(isActive ? AetherDesign.Palette.accent : AetherDesign.Palette.textPrimary)
            .padding(AetherDesign.Spacing.s)
            .background(.ultraThinMaterial, in: Circle())
            .shadow(color: .black.opacity(isFocused ? 0.45 : 0.0),
                    radius: isFocused ? 14 : 0,
                    y: isFocused ? 8 : 0)
            .scaleEffect(isFocused ? 1.10 : 1.0)
            .animation(AetherDesign.Motion.focus, value: isFocused)
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
