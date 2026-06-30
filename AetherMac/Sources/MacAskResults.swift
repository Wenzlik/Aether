import SwiftUI
import AetherCore

/// macOS **Ask Aether** result surface — the mac-native counterpart of the iOS
/// `RecommendationResultsView`. Shows "In your library" matches, "More like …",
/// and a "Suggested by Aether" pick with its reason, using `MacPoster` cards with
/// the same play / mark-watched context menu as `MacSearchResults`. Every row
/// navigates into Detail via the host's `UnifiedMediaItem` destination.
struct MacAskResults: View {
    let session: MacSession
    let result: AskResult
    /// Set when the user edited the field since this answer — shows the hint.
    var pendingQuery: String?

    private let gridColumns = [GridItem(.adaptive(minimum: 162, maximum: 220), spacing: 24)]
    private let railWidth: CGFloat = 168

    private var matches: [UnifiedMediaItem] { result.libraryMatches }
    private var pick: UnifiedMediaItem? { result.recommendation?.pick }
    private var more: [UnifiedMediaItem] {
        guard let pick else { return [] }
        return (result.recommendation?.shortlist ?? []).filter { $0.id != pick.id }
    }

    var body: some View {
        if result.isEmpty {
            ContentUnavailableView(
                "Nothing found",
                systemImage: "sparkles",
                description: Text("Aether couldn't find or suggest anything. Try different words.")
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let pendingQuery { pendingHint(pendingQuery) }
                    if !matches.isEmpty {
                        section("In your library") { grid(matches) }
                    }
                    if !result.similar.isEmpty {
                        let title = result.similarTo.map { String(localized: "More like \($0)") }
                            ?? String(localized: "More like this")
                        section(title) { rail(result.similar) }
                    }
                    if let pick {
                        heroPick(pick)
                        if !more.isEmpty { section("More to consider") { rail(more) } }
                    }
                }
                .padding(24)
            }
        }
    }

    // MARK: - Hero pick

    @ViewBuilder private func heroPick(_ pick: UnifiedMediaItem) -> some View {
        let usedAI = result.recommendation?.usedAI ?? false
        VStack(alignment: .leading, spacing: 10) {
            Label {
                if usedAI { Text("Suggested by Aether") } else { Text("Top match") }
            } icon: {
                Image(systemName: usedAI ? "sparkles" : "star.fill")
            }
            .font(.headline)
            .foregroundStyle(AetherMacTheme.accent)

            NavigationLink(value: pick) {
                HStack(alignment: .top, spacing: 16) {
                    MacPoster(item: pick, width: 150)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(pick.title)
                            .font(.title2).fontWeight(.semibold)
                            .foregroundStyle(.primary).lineLimit(2)
                        if let meta = metaLine(pick) {
                            Text(verbatim: meta).font(.subheadline).foregroundStyle(.secondary)
                        }
                        if session.playbackPrefs.showRecommendationReasons,
                           let reason = result.recommendation?.reason {
                            Text(verbatim: "“\(reason)”")
                                .font(.body).foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Picked from titles you already own.")
                                .font(.body).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .contextMenu { playMenu(pick) }
        }
    }

    // MARK: - Building blocks

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringKey(title)).font(.title3).fontWeight(.semibold)
            content()
        }
    }

    private func grid(_ items: [UnifiedMediaItem]) -> some View {
        LazyVGrid(columns: gridColumns, spacing: 24) {
            ForEach(items) { posterLink($0, width: nil) }
        }
    }

    private func rail(_ items: [UnifiedMediaItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 18) {
                ForEach(items) { posterLink($0, width: railWidth) }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder private func posterLink(_ item: UnifiedMediaItem, width: CGFloat?) -> some View {
        NavigationLink(value: item) { MacPoster(item: item, width: width) }
            .buttonStyle(.plain)
            .contextMenu { playMenu(item) }
    }

    @ViewBuilder private func playMenu(_ item: UnifiedMediaItem) -> some View {
        if let base = item.preferredSource?.item ?? item.sources.first?.item {
            Button { Task { await session.play(base) } } label: {
                Label("Play", systemImage: "play.fill")
            }
            Divider()
            Button {
                Task { await session.markWatched(base, watched: !item.isFullyWatched) }
            } label: {
                Label(
                    item.isFullyWatched ? "Mark as Unwatched" : "Mark as Watched",
                    systemImage: item.isFullyWatched ? "circle" : "checkmark.circle"
                )
            }
        }
    }

    private func pendingHint(_ pending: String) -> some View {
        Label {
            Text("Press return to ask: “\(pending)”").lineLimit(1)
        } icon: {
            Image(systemName: "return")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func metaLine(_ pick: UnifiedMediaItem) -> String? {
        var parts: [String] = []
        if let year = pick.year { parts.append(String(year)) }
        if !pick.genres.isEmpty { parts.append(pick.genres.prefix(2).joined(separator: " · ")) }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }
}
