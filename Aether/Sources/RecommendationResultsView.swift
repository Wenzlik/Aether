import SwiftUI
import AetherCore

/// The **Ask Aether** result surface — shown in `SearchView` after the user
/// submits a natural-language request ("a scary movie under 2 hours").
///
/// It presents the single grounded pick with the model's one-line reason, then
/// the rest of the engine's shortlist as "More to consider". Every title is a
/// real `UnifiedMediaItem`, so each row navigates straight into Detail (where
/// Play / Resume already live) via the host's `mediaNavigationDestinations`.
struct RecommendationResultsView: View {
    let result: RecommendationResult
    /// The request the user typed — echoed in the empty state.
    let query: String

    @Environment(WatchAvailabilityStore.self) private var availability: WatchAvailabilityStore?

    var body: some View {
        if let pick = result.pick {
            ScrollView {
                VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                    heroPick(pick)
                    if !more.isEmpty { moreRail }
                }
                .padding(.vertical, AetherDesign.Spacing.l)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            AetherEmptyState(
                glyph: "sparkles",
                title: "No match found",
                message: "Aether couldn't find something for “\(query)”. Try different words."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The shortlist minus the hero pick.
    private var more: [UnifiedMediaItem] {
        guard let pick = result.pick else { return [] }
        return result.shortlist.filter { $0.id != pick.id }
    }

    // MARK: - Hero pick

    private func heroPick(_ pick: UnifiedMediaItem) -> some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            HStack(spacing: AetherDesign.Spacing.xs) {
                Image(systemName: result.usedAI ? "sparkles" : "star.fill")
                if result.usedAI {
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
                        if let reason = result.reason {
                            Text(verbatim: "“\(reason)”")
                                .font(AetherDesign.Typography.body)
                                .foregroundStyle(AetherDesign.Palette.textPrimary)
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

    // MARK: - More rail

    private var moreRail: some View {
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
