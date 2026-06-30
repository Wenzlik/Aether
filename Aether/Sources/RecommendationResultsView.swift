import SwiftUI
import AetherCore

// `AskResult` + the `AskAether` query logic now live in AetherCore (shared with
// macOS). This file is just the iOS result surface.

/// The Ask Aether result surface, shown in `SearchView` after submit. Every row
/// is a real `UnifiedMediaItem`, so it navigates into Detail (Play / Resume) via
/// the host's `mediaNavigationDestinations`.
struct RecommendationResultsView: View {
    let result: AskResult
    /// Set when the user has edited the field since this answer was produced;
    /// shows a "press Return to ask again" hint so editing doesn't feel stuck.
    var pendingQuery: String?
    /// Honour the "Show recommendation reasons" Settings toggle. When off (or on
    /// the deterministic path, which has no prose), a short fallback line stands
    /// in for the AI reason so the hero never reads as bare.
    var showReasons: Bool = true

    @Environment(WatchAvailabilityStore.self) private var availability: WatchAvailabilityStore?

    private var matches: [UnifiedMediaItem] { result.libraryMatches }
    private var pick: UnifiedMediaItem? { result.recommendation?.pick }

    var body: some View {
        if matches.isEmpty && pick == nil && result.similar.isEmpty {
            AetherEmptyState(
                glyph: "sparkles",
                title: "Nothing found",
                message: "Aether couldn't find or suggest anything. Try different words."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                    if let pendingQuery { pendingHint(pendingQuery) }
                    if !matches.isEmpty { librarySection }
                    if !result.similar.isEmpty { similarSection }
                    if let pick { recommendationSection(pick) }
                }
                .padding(.vertical, AetherDesign.Spacing.l)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Pending-edit hint

    private func pendingHint(_ pending: String) -> some View {
        HStack(spacing: AetherDesign.Spacing.xs) {
            Image(systemName: "return")
            Text("Press return to ask: “\(pending)”")
                .lineLimit(1)
        }
        .font(AetherDesign.Typography.caption)
        .foregroundStyle(AetherDesign.Palette.textSecondary)
        .padding(.horizontal, AetherDesign.Spacing.l)
    }

    // MARK: - Library matches

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            AetherSectionHeader(title: "In your library")
            LazyVGrid(columns: columns, spacing: AetherDesign.Spacing.l) {
                ForEach(matches) { item in
                    NavigationLink(value: item) {
                        AetherCard.poster(
                            title: item.title,
                            posterURL: item.posterURL,
                            isWatched: item.isFullyWatched,
                            netflixLogoURL: availability?.netflixLogoURL(for: item)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, AetherDesign.Spacing.l)
        }
    }

    // MARK: - More like this (TMDb)

    private var similarSection: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            AetherSectionHeader(title: result.similarTo.map { String(localized: "More like \($0)") } ?? "More like this")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: AetherDesign.Spacing.l) {
                    ForEach(result.similar) { item in
                        NavigationLink(value: item) {
                            AetherCard.poster(
                                title: item.title,
                                posterURL: item.posterURL,
                                isWatched: item.isFullyWatched,
                                netflixLogoURL: availability?.netflixLogoURL(for: item)
                            )
                            .frame(width: cardWidth)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, AetherDesign.Spacing.l)
                .padding(.vertical, AetherDesign.Spacing.xs)
            }
        }
    }

    // MARK: - Recommendation

    private func recommendationSection(_ pick: UnifiedMediaItem) -> some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
            heroPick(pick)
            let more = (result.recommendation?.shortlist ?? []).filter { $0.id != pick.id }
            if !more.isEmpty { moreRail(more) }
        }
    }

    private func heroPick(_ pick: UnifiedMediaItem) -> some View {
        let usedAI = result.recommendation?.usedAI ?? false
        return VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            HStack(spacing: AetherDesign.Spacing.xs) {
                Image(systemName: usedAI ? "sparkles" : "star.fill")
                if usedAI {
                    Text("Suggested by Aether")
                } else {
                    Text("Top match")
                }
            }
            .font(AetherDesign.Typography.metadata)
            .foregroundStyle(AetherDesign.Palette.accent)
            .padding(.horizontal, AetherDesign.Spacing.l)

            NavigationLink(value: pick) {
                HStack(alignment: .top, spacing: AetherDesign.Spacing.l) {
                    AetherCard.poster(
                        title: pick.title,
                        posterURL: pick.posterURL,
                        isWatched: pick.isFullyWatched,
                        netflixLogoURL: availability?.netflixLogoURL(for: pick)
                    )
                    .frame(width: heroPosterWidth)

                    VStack(alignment: .leading, spacing: AetherDesign.Spacing.s) {
                        Text(pick.title)
                            .font(AetherDesign.Typography.sectionTitle)
                            .foregroundStyle(AetherDesign.Palette.textPrimary)
                            .lineLimit(2)
                        if let meta = metaLine(pick) {
                            Text(verbatim: meta)
                                .font(AetherDesign.Typography.metadata)
                                .foregroundStyle(AetherDesign.Palette.textSecondary)
                        }
                        if showReasons, let reason = result.recommendation?.reason {
                            Text(verbatim: "“\(reason)”")
                                .font(AetherDesign.Typography.body)
                                .foregroundStyle(AetherDesign.Palette.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Picked from titles you already own.")
                                .font(AetherDesign.Typography.body)
                                .foregroundStyle(AetherDesign.Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("View details")
                            .font(AetherDesign.Typography.metadata)
                            .foregroundStyle(AetherDesign.Palette.accent)
                            .padding(.top, AetherDesign.Spacing.xs)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, AetherDesign.Spacing.l)
            }
            .buttonStyle(.plain)
        }
    }

    private func moreRail(_ more: [UnifiedMediaItem]) -> some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            AetherSectionHeader(title: "More to consider")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: AetherDesign.Spacing.l) {
                    ForEach(more) { item in
                        NavigationLink(value: item) {
                            AetherCard.poster(
                                title: item.title,
                                posterURL: item.posterURL,
                                isWatched: item.isFullyWatched,
                                netflixLogoURL: availability?.netflixLogoURL(for: item)
                            )
                            .frame(width: cardWidth)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, AetherDesign.Spacing.l)
                .padding(.vertical, AetherDesign.Spacing.xs)
            }
        }
    }

    private func metaLine(_ pick: UnifiedMediaItem) -> String? {
        var parts: [String] = []
        if let year = pick.year { parts.append(String(year)) }
        if !pick.genres.isEmpty { parts.append(pick.genres.prefix(2).joined(separator: " · ")) }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    private var columns: [GridItem] {
        #if os(tvOS)
        [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: AetherDesign.Spacing.l)]
        #else
        [GridItem(.adaptive(minimum: 120, maximum: 180), spacing: AetherDesign.Spacing.m)]
        #endif
    }

    private var heroPosterWidth: CGFloat {
        #if os(tvOS)
        220
        #else
        140
        #endif
    }

    private var cardWidth: CGFloat {
        #if os(tvOS)
        300
        #else
        168
        #endif
    }
}
