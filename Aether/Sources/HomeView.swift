import SwiftUI
import AetherCore

struct HomeView: View {
    let source: any MediaSource
    let resumeStore: ResumeStore
    let playbackSession: PlaybackSession

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
                    } else {
                        if !feed.featured.isEmpty {
                            section(title: "Featured", items: feed.featured, aspect: .poster)
                        }

                        if !feed.continueWatching.isEmpty {
                            continueWatchingSection
                        }

                        ForEach(feed.libraries) { librarySection in
                            section(
                                title: librarySection.library.title,
                                items: librarySection.items,
                                aspect: librarySection.library.kind == .show ? .episode : .poster
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
        .task { await load() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
            Text("Aether")
                .font(AetherDesign.Typography.heroTitle)
                .foregroundStyle(AetherDesign.Palette.textPrimary)
            Text("Personal media, beautifully played.")
                .font(AetherDesign.Typography.metadata)
                .foregroundStyle(AetherDesign.Palette.textSecondary)
        }
        .padding(.horizontal, AetherDesign.Spacing.l)
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
            switch self {
            case .poster: return 160
            case .episode: return 280
            }
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
        }
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
