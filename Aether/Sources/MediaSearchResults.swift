import SwiftUI
import AetherCore

/// Search-results body shared by `HomeView` and `LibraryBrowseView`.
///
/// Both tabs carry a search field — when the user types, the host swaps its
/// content (rails / grid) for this view. It searches **across every source it's
/// given** and returns **unified** results: one row per title, deduplicated via
/// the same external-ID merge as Home. Home passes all connected sources
/// (unified search); Library passes its single active source (until Library is
/// unified in a later phase).
///
/// **Data:** loads one page of items per library per source on appear, merges +
/// dedupes, and filters client-side by `title.localizedCaseInsensitiveContains`.
/// Each result navigates the `UnifiedMediaItem` itself, so Detail receives the
/// full source list for its "Available Sources" section.
struct MediaSearchResults: View {
    let sources: [any MediaSource]
    let query: String

    @Environment(WatchAvailabilityStore.self) private var availability: WatchAvailabilityStore?

    @State private var items: [UnifiedMediaItem] = []
    /// Netflix-only matches for the query (#360) — appended after owned results,
    /// deduped against them. Empty unless the feature + "show Netflix-only" are on.
    @State private var netflixResults: [UnifiedMediaItem] = []
    @State private var isLoading = false
    /// People (actors + directors) across the sources, loaded once with the
    /// catalog so name matching is client-side (#296) — no per-keystroke server
    /// query. Holds the owning source so we can fetch a person's titles.
    @State private var peopleIndex: [PersonHit] = []
    /// Titles derived from the people whose name matches the current query.
    @State private var personItems: [UnifiedMediaItem] = []

    private struct PersonHit { let person: MediaPerson; let source: any MediaSource }

    var body: some View {
        content
            .task(id: sourcesKey) { await load() }
            // Debounced person lookup, re-run as the query changes (#296).
            .task(id: query) { await loadPersonMatches() }
            // Netflix-only matches, re-run as the query changes (#360).
            .task(id: query) { await loadNetflixMatches() }
    }

    /// Netflix-only titles matching the query (#360) — appended to results,
    /// deduped against owned. No-op unless the feature + "show Netflix-only" are
    /// on. Cancelled + re-run per query via `.task(id: query)`.
    private func loadNetflixMatches() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let availability, availability.showsNetflixOnly, trimmed.count >= 2 else {
            netflixResults = []
            return
        }
        netflixResults = await availability.netflixOnlySearch(trimmed)
    }

    /// Stable reload key across the given sources.
    private var sourcesKey: String {
        sources.map { $0.id.stableKey }.sorted().joined(separator: ",")
    }

    @ViewBuilder
    private var content: some View {
        if sources.isEmpty {
            AetherEmptyState(
                glyph: "magnifyingglass",
                title: "Nothing to search yet",
                message: "Connect a source and your movies and shows become searchable here."
            )
            // Fill the screen so the results area never collapses to its intrinsic
            // height while typing (which shrank the view and broke tap/scroll
            // keyboard dismissal). Matches the discovery state's full-screen frame.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isLoading && items.isEmpty {
            AetherLoadingDots(caption: "Searching…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            AetherEmptyState(
                glyph: "questionmark.circle",
                title: "No matches",
                message: "Nothing in your library matches “\(query)”."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: AetherDesign.Spacing.l) {
                    ForEach(results) { unified in
                        NavigationLink(value: unified) {
                            AetherCard.poster(title: unified.title, posterURL: unified.posterURL, isWatched: unified.isFullyWatched, netflixLogoURL: availability?.netflixLogoURL(for: unified))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(AetherDesign.Spacing.l)
            }
        }
    }

    private var results: [UnifiedMediaItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // Title matches first; then titles surfaced by a matching actor/director
        // name (#296), deduped against the title hits. Match is diacritic- and
        // case-insensitive so "pribehy" finds "Příběhy" (#345); matching across
        // original/localized title variants waits on #344.
        let titleMatches = items.filter {
            $0.title.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        var seen = Set(titleMatches.map(\.id))
        let personDerived = personItems.filter { seen.insert($0.id).inserted }
        // Netflix-only matches (#360) last, deduped against owned results — both
        // by unified id and by the owned TMDb ids, so an owned title that's also
        // on Netflix isn't duplicated as a Netflix-only poster.
        let ownedTMDb = Set((titleMatches + personDerived).compactMap(\.tmdbID))
        let netflixOnly = netflixResults.filter {
            guard seen.insert($0.id).inserted else { return false }
            return $0.tmdbID.map { !ownedTMDb.contains($0) } ?? true
        }
        return titleMatches + personDerived + netflixOnly
    }

    private var columns: [GridItem] {
        #if os(tvOS)
        [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: AetherDesign.Spacing.l)]
        #else
        [GridItem(.adaptive(minimum: 120, maximum: 180), spacing: AetherDesign.Spacing.m)]
        #endif
    }

    /// One page of items per library across every source, merged + deduped.
    /// Fault-tolerant: a source that fails to list/fetch is skipped.
    private func load() async {
        guard !sources.isEmpty else {
            items = []
            return
        }
        isLoading = true
        defer { isLoading = false }

        var collected: [MediaItem] = []
        for source in sources {
            guard let libraries = try? await source.libraries() else { continue }
            for library in libraries {
                if let fetched = try? await source.items(in: library.id) {
                    collected += fetched
                }
            }
        }
        items = UnifiedLibrary.merge(collected)

        // People index (#296): actors + directors per source, capped, so query
        // matching stays client-side. Loaded once alongside the catalog.
        var index: [PersonHit] = []
        for source in sources where source.supportsPeople {
            for kind in [PersonKind.actor, .director] {
                let people = await source.people(kind)
                index += people.prefix(2000).map { PersonHit(person: $0, source: source) }
            }
        }
        peopleIndex = index
    }

    /// Resolve titles for the people whose name matches the query. Debounced and
    /// re-run per query (the `.task(id: query)` cancels the prior run), and
    /// capped to a handful of people — so typing never fires an unbounded number
    /// of `items(withPerson:)` calls (#296).
    private func loadPersonMatches() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Skip 0–1 char queries (every actor would "match") and empty state.
        guard trimmed.count >= 2 else { personItems = []; return }
        // Debounce: let typing settle before hitting the network.
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }

        let matches = peopleIndex
            .filter { $0.person.name.localizedCaseInsensitiveContains(trimmed) }
            .prefix(8)
        guard !matches.isEmpty else { personItems = []; return }

        var collected: [MediaItem] = []
        for match in matches {
            collected += await match.source.items(withPerson: match.person)
        }
        guard !Task.isCancelled else { return }
        personItems = UnifiedLibrary.merge(collected)
    }
}
