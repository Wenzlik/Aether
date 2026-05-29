import SwiftUI
import AetherCore

struct HomeView: View {
    let source: any MediaSource
    let resumeStore: ResumeStore
    let playbackSession: PlaybackSession
    let isPlexSignedIn: Bool
    let plexServerName: String?
    let plexDiscoveryState: AppSession.DiscoveryState
    let onAddSource: () -> Void
    let onRetryDiscovery: () -> Void

    @State private var feed: HomeFeed = .empty
    @State private var loadError: String?
    @State private var isLoading = true

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
                            section(title: "Featured", items: feed.featured, aspect: .poster)
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
                    resumeStore: resumeStore,
                    playbackSession: playbackSession
                )
            }
        }
        // Re-run load() whenever the underlying source changes (e.g. mock →
        // plexSource after AppSession.start() finishes discovery). Without
        // the id:, .task fires once on first appear and would leave Home
        // showing whatever it loaded first.
        .task(id: source.id) { await load() }
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

            // Always-visible account / source button so the sign-in flow is
            // reachable even when the mock library has plenty of content (which
            // hides the empty state CTA). Icon changes based on the current
            // state: idle plus badge → signed-in person → filled person.
            Button(action: onAddSource) {
                AccountBadge(
                    glyph: accountGlyph,
                    isActive: plexServerName != nil
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accountAccessibilityLabel)
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
            case .poster: return 260
            case .episode: return 440
            }
            #else
            switch self {
            case .poster: return 160
            case .episode: return 280
            }
            #endif
        }
    }

    private func section(title: String, items: [MediaItem], aspect: CardAspect) -> some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            SectionHeader(title: title)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: AetherDesign.Spacing.m) {
                    ForEach(items) { item in
                        NavigationLink(value: item) {
                            CardView(
                                title: item.title,
                                posterURL: item.posterURL,
                                aspectRatio: aspect.ratio
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

    // MARK: - Continue Watching section (carries progress overlay)

    private var continueWatchingSection: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            SectionHeader(title: "Continue Watching", subtitle: "Pick up where you left off")

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: AetherDesign.Spacing.m) {
                    ForEach(feed.continueWatching) { entry in
                        NavigationLink(value: entry.item) {
                            CardView(
                                title: entry.item.title,
                                posterURL: entry.item.backdropURL ?? entry.item.posterURL,
                                aspectRatio: 16.0 / 9.0,
                                progress: entry.progress
                            )
                            .frame(width: 280)
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
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            Image(systemName: emptyStateGlyph)
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(AetherDesign.Palette.textTertiary)
                .padding(.bottom, AetherDesign.Spacing.s)

            Text(emptyStateTitle)
                .font(AetherDesign.Typography.sectionTitle)
                .foregroundStyle(AetherDesign.Palette.textPrimary)

            HStack(spacing: AetherDesign.Spacing.s) {
                if isDiscoveryInFlight {
                    ProgressView()
                        .tint(AetherDesign.Palette.textSecondary)
                }
                Text(emptyStateBody)
                    .font(AetherDesign.Typography.body)
                    .foregroundStyle(AetherDesign.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            emptyStatePrimaryAction
                .padding(.top, AetherDesign.Spacing.s)
        }
        .padding(.horizontal, AetherDesign.Spacing.l)
        .padding(.top, AetherDesign.Spacing.xxl)
        .frame(maxWidth: 520, alignment: .leading)
    }

    @ViewBuilder
    private var emptyStatePrimaryAction: some View {
        if !isPlexSignedIn {
            primaryActionCapsule(title: "Add a source", action: onAddSource)
        } else if case .noServersFound = plexDiscoveryState {
            primaryActionCapsule(title: "Try again", action: onRetryDiscovery)
        } else if case .failed = plexDiscoveryState {
            primaryActionCapsule(title: "Try again", action: onRetryDiscovery)
        }
        // .discovering / .idle / .completed → no CTA
    }

    private func primaryActionCapsule(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(AetherDesign.Typography.cardTitle)
                .padding(.horizontal, AetherDesign.Spacing.l)
                .padding(.vertical, AetherDesign.Spacing.s)
                .background(AetherDesign.Palette.accent.opacity(0.20), in: Capsule())
                .foregroundStyle(AetherDesign.Palette.textPrimary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Loading & error states

    private var loadingState: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            ForEach(0..<2, id: \.self) { _ in
                Rectangle()
                    .fill(AetherDesign.Palette.surface)
                    .frame(height: 22)
                    .frame(maxWidth: 220, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(.horizontal, AetherDesign.Spacing.l)

                HStack(spacing: AetherDesign.Spacing.m) {
                    ForEach(0..<4, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                            .fill(AetherDesign.Palette.surface)
                            .frame(width: 160, height: 240)
                    }
                }
                .padding(.horizontal, AetherDesign.Spacing.l)
            }
        }
        .redacted(reason: .placeholder)
    }

    private func errorState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.s) {
            Text("Couldn't load library")
                .font(AetherDesign.Typography.sectionTitle)
                .foregroundStyle(AetherDesign.Palette.textPrimary)
            Text(message)
                .font(AetherDesign.Typography.body)
                .foregroundStyle(AetherDesign.Palette.textSecondary)
        }
        .padding(.horizontal, AetherDesign.Spacing.l)
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let builder = HomeFeedBuilder()
            let curatedFeatured = await (source as? MockMediaSource)?.featuredItems
            feed = try await builder.build(
                source: source,
                resumeStore: resumeStore,
                featured: curatedFeatured
            )
        } catch {
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
