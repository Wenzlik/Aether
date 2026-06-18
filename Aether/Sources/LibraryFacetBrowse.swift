import SwiftUI
import AetherCore

/// Library browsing by **server-side facets** — Collections, Actors, Directors
/// (#273). Unlike Genres / Years (client-side filters over the already-fetched
/// catalog, `LibraryGenreBrowse.swift`), these need per-source server queries:
/// the lists fan out `collections()` / `people(_:)` across connected sources and
/// dedupe by name; the grids aggregate `items(inCollection:)` /
/// `items(withPerson:)` from every contributing source.

// MARK: - Facet entries (cross-source merge)

/// One display row backed by every source's matching facet value — e.g. the
/// "Marvel" collection on both Plex and Jellyfin collapses to one row whose
/// grid queries both.
struct CollectionEntry: Identifiable, Hashable, Sendable {
    var id: String { title.lowercased() }
    let title: String
    let childCount: Int?
    let members: [MediaCollection]
}

struct PersonEntry: Identifiable, Hashable, Sendable {
    var id: String { name.lowercased() }
    let name: String
    let kind: PersonKind
    let members: [MediaPerson]
    /// First available headshot across the deduped source variants (#297).
    var photoURL: URL? {
        members.lazy.compactMap { $0.artwork?.posterURL(.thumbnail) }.first
    }
}

/// Process-shared cache for the deduped facet lists. Collections / Actors /
/// Directors fan out to every server on each visit, which read as a long blank
/// load; cache the result (keyed by the source set + kind) so re-visits are
/// instant within a session. Long-ish TTL — facets change rarely.
actor FacetCache {
    static let shared = FacetCache()

    private struct Entry<Value> { let value: Value; let at: ContinuousClock.Instant }
    private var collectionStore: [String: Entry<[CollectionEntry]>] = [:]
    private var peopleStore: [String: Entry<[PersonEntry]>] = [:]
    private let ttl: Duration = .seconds(10 * 60)
    private let clock = ContinuousClock()

    func collections(for key: String) -> [CollectionEntry]? {
        guard let e = collectionStore[key], e.at.duration(to: clock.now) < ttl else { return nil }
        return e.value
    }
    func setCollections(_ value: [CollectionEntry], for key: String) {
        guard !value.isEmpty else { return }
        collectionStore[key] = Entry(value: value, at: clock.now)
    }
    func people(for key: String) -> [PersonEntry]? {
        guard let e = peopleStore[key], e.at.duration(to: clock.now) < ttl else { return nil }
        return e.value
    }
    func setPeople(_ value: [PersonEntry], for key: String) {
        guard !value.isEmpty else { return }
        peopleStore[key] = Entry(value: value, at: clock.now)
    }
}

// MARK: - Collections

/// Every collection across the connected sources, deduped by title.
struct CollectionListView: View {
    let connectedSources: [any MediaSource]

    @State private var entries: [CollectionEntry] = []
    @State private var isLoading = false

    private var sourcesKey: String {
        connectedSources.map { $0.id.stableKey }.sorted().joined(separator: ",")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                #if os(tvOS)
                Text("Collections")
                    .font(AetherDesign.Typography.heroTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                #endif
                if isLoading && entries.isEmpty {
                    AetherLoadingState(.inline)
                } else if entries.isEmpty {
                    AetherEmptyState(glyph: "square.stack", title: "No collections",
                                     message: "Your connected sources don't have any collections yet.")
                } else {
                    LazyVStack(spacing: AetherDesign.Spacing.m) {
                        ForEach(entries) { entry in
                            NavigationLink(value: LibraryBrowseRoute.collection(entry)) {
                                LibraryBrowseRow(title: entry.title, detail: entry.childCount.map { "\($0) titles" })
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, AetherDesign.Spacing.xl)
            .padding(.vertical, AetherDesign.Spacing.l)
        }
        .aetherScreenBackground()
        #if !os(tvOS)
        .navigationTitle("Collections")
        #endif
        .task(id: sourcesKey) { await load() }
    }

    private func load() async {
        guard !connectedSources.isEmpty else { entries = []; return }
        if let cached = await FacetCache.shared.collections(for: sourcesKey) {
            entries = cached
            return
        }
        isLoading = true
        defer { isLoading = false }
        var bySlug: [String: (title: String, count: Int?, members: [MediaCollection])] = [:]
        await withTaskGroup(of: [MediaCollection].self) { group in
            for source in connectedSources where source.supportsCollections {
                group.addTask { await source.collections() }
            }
            for await collections in group {
                for collection in collections {
                    let slug = collection.title.lowercased().trimmingCharacters(in: .whitespaces)
                    var entry = bySlug[slug] ?? (collection.title, nil, [])
                    entry.count = max(entry.count ?? 0, collection.childCount ?? 0)
                    entry.members.append(collection)
                    bySlug[slug] = entry
                }
            }
        }
        entries = bySlug.values
            .map { CollectionEntry(title: $0.title, childCount: ($0.count ?? 0) > 0 ? $0.count : nil, members: $0.members) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        await FacetCache.shared.setCollections(entries, for: sourcesKey)
    }
}

// MARK: - People

/// Every actor / director across the connected sources, deduped by name.
struct PersonListView: View {
    let kind: PersonKind
    let connectedSources: [any MediaSource]

    @State private var entries: [PersonEntry] = []
    @State private var isLoading = false
    /// Quick in-list narrowing — people lists run long (hundreds of names).
    @State private var filter = ""

    private var title: String { kind == .actor ? "Actors" : "Directors" }

    private var sourcesKey: String {
        connectedSources.map { $0.id.stableKey }.sorted().joined(separator: ",") + "|\(kind.rawValue)"
    }

    private var visibleEntries: [PersonEntry] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(needle) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                #if os(tvOS)
                Text(title)
                    .font(AetherDesign.Typography.heroTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                #endif
                if isLoading && entries.isEmpty {
                    AetherLoadingState(.inline)
                } else if entries.isEmpty {
                    AetherEmptyState(glyph: "person.2", title: "No \(title.lowercased())",
                                     message: "Your connected sources don't list \(title.lowercased()) yet.")
                } else {
                    #if !os(tvOS)
                    AetherSearchField(text: $filter, prompt: "Filter \(title.lowercased())")
                    #endif
                    LazyVStack(spacing: AetherDesign.Spacing.m) {
                        ForEach(visibleEntries) { entry in
                            NavigationLink(value: LibraryBrowseRoute.person(entry)) {
                                LibraryBrowseRow(title: entry.name, photoURL: entry.photoURL, showsHeadshot: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, AetherDesign.Spacing.xl)
            .padding(.vertical, AetherDesign.Spacing.l)
        }
        .aetherScreenBackground()
        #if !os(tvOS)
        .navigationTitle(title)
        #endif
        .task(id: sourcesKey) { await load() }
    }

    private func load() async {
        guard !connectedSources.isEmpty else { entries = []; return }
        if let cached = await FacetCache.shared.people(for: sourcesKey) {
            entries = cached
            return
        }
        isLoading = true
        defer { isLoading = false }
        let kind = self.kind
        var bySlug: [String: (name: String, members: [MediaPerson])] = [:]
        await withTaskGroup(of: [MediaPerson].self) { group in
            for source in connectedSources where source.supportsPeople {
                group.addTask { await source.people(kind) }
            }
            for await people in group {
                for person in people {
                    let slug = person.name.lowercased().trimmingCharacters(in: .whitespaces)
                    var entry = bySlug[slug] ?? (person.name, [])
                    entry.members.append(person)
                    bySlug[slug] = entry
                }
            }
        }
        entries = bySlug.values
            .map { PersonEntry(name: $0.name, kind: kind, members: $0.members) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        await FacetCache.shared.setPeople(entries, for: sourcesKey)
    }
}

// MARK: - Facet item aggregation

/// A collection entry's titles, aggregated from every member source (serial —
/// at most a couple of connected sources).
func collectionItems(for entry: CollectionEntry, sources: [any MediaSource]) async -> [MediaItem] {
    var all: [MediaItem] = []
    for member in entry.members {
        guard let source = sources.first(where: { $0.id == member.id.source }) else { continue }
        all += await source.items(inCollection: member.id)
    }
    return all
}

/// A person entry's filmography, aggregated from every member source.
func personItems(for entry: PersonEntry, sources: [any MediaSource]) async -> [MediaItem] {
    var all: [MediaItem] = []
    for member in entry.members {
        guard let source = sources.first(where: { $0.id == member.id.source }) else { continue }
        all += await source.items(withPerson: member)
    }
    return all
}

// MARK: - Facet items grid

/// A grid of titles resolved by a **server query** (collection members, a
/// person's filmography) — the loader-based sibling of `FacetGridView`, which
/// filters the local catalog instead.
struct SourceFacetGridView: View {
    let title: String
    let downloadStore: DownloadStore?
    let load: () async -> [MediaItem]

    @Environment(WatchAvailabilityStore.self) private var availability: WatchAvailabilityStore?
    @Environment(\.posterRatingSource) private var posterRatingSource

    @State private var items: [MediaItem] = []
    @State private var isLoading = false

    private var columns: [GridItem] {
        #if os(tvOS)
        [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: AetherDesign.Spacing.l)]
        #else
        [GridItem(.adaptive(minimum: 120, maximum: 180), spacing: AetherDesign.Spacing.m)]
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                #if os(tvOS)
                Text(title)
                    .font(AetherDesign.Typography.heroTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                #endif
                if isLoading && items.isEmpty {
                    AetherLoadingState(.inline)
                } else if items.isEmpty {
                    AetherEmptyState(glyph: "tray", title: "Nothing here yet",
                                     message: "No titles found for \(title) across your connected sources.")
                } else {
                    LazyVGrid(columns: columns, spacing: AetherDesign.Spacing.l) {
                        ForEach(items) { item in
                            NavigationLink(value: item) {
                                AetherCard.poster(title: item.displayTitle, posterURL: item.posterURL, isWatched: item.isFullyWatched, rating: item.posterRating(source: posterRatingSource), netflixLogoURL: availability?.netflixLogoURL(for: item))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, AetherDesign.Spacing.l)
            .padding(.vertical, AetherDesign.Spacing.l)
        }
        .aetherScreenBackground()
        #if !os(tvOS)
        .navigationTitle(title)
        #endif
        .task(id: title) {
            guard items.isEmpty else { return }
            isLoading = true
            defer { isLoading = false }
            let fetched = await load()
            // Light cross-source dedupe by (title, year) — first source wins.
            var seen: Set<String> = []
            items = fetched.filter { seen.insert("\($0.title.lowercased())|\($0.year ?? 0)").inserted }
        }
    }
}
