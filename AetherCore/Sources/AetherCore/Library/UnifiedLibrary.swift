import Foundation

/// Unified Library: fans out across every connected source, fetches its items,
/// and merges them into deduplicated `UnifiedMediaItem`s with offline copies
/// surfaced as a source.
///
/// The pure merge logic (`merge(...)`, Phase 1b) is `nonisolated static` and
/// fully unit-tested; the actor adds the fault-tolerant fan-out (Phase 2) that
/// the views consume. The single hard part — identity + merging — stays
/// isolated and testable.
///
/// **Deduplication** is union-find over shared external IDs: two items merge if
/// they share *any* of TMDB / IMDB / TVDB (so a Plex item with TMDB+IMDB merges
/// with a Jellyfin item that only exposes IMDB). Items with no external ID fall
/// back to normalised title + year, and merge only with others that match
/// exactly — conservative, to avoid false merges. Items with neither never
/// merge (one row per source).
public actor UnifiedLibrary {
    private let sources: [any MediaSource]
    private let downloads: DownloadStore?

    public init(sources: [any MediaSource], downloads: DownloadStore? = nil) {
        self.sources = sources
        self.downloads = downloads
    }

    /// Server display names keyed by source id, derived from the sources
    /// themselves (for the unified "Available Sources" rows).
    private var serverNames: [MediaSourceID: String] {
        Dictionary(sources.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    }

    /// All unified titles of `kind` across connected sources. Fault-tolerant: a
    /// source that fails to list libraries or items is skipped, not fatal, so a
    /// slow/down server never blanks the feed.
    public func unifiedItems(kind: MediaItem.Kind) async -> [UnifiedMediaItem] {
        // Fan out across sources concurrently (and each source's libraries
        // concurrently) instead of serially — the serial version made Home /
        // Library wait for the slowest server's last library before first paint.
        async let downloadedTask = downloadedIDs()
        let items = await withTaskGroup(of: [MediaItem].self) { group in
            for source in sources {
                group.addTask {
                    guard let libraries = try? await source.libraries() else { return [] }
                    return await withTaskGroup(of: [MediaItem].self) { inner in
                        for library in libraries where library.kind == kind {
                            inner.addTask { (try? await source.items(in: library.id)) ?? [] }
                        }
                        var acc: [MediaItem] = []
                        for await chunk in inner { acc += chunk }
                        return acc
                    }
                }
            }
            var all: [MediaItem] = []
            for await chunk in group { all += chunk }
            return all
        }
        let downloaded = await downloadedTask
        return Self.merge(items, downloaded: downloaded, serverNames: serverNames)
    }

    private func downloadedIDs() async -> Set<MediaID> {
        guard let downloads else { return [] }
        return Set(await downloads.snapshot().completed.map(\.mediaID))
    }

    /// Build the unified Home rails: deduplicated Movies / TV Shows, plus
    /// cross-source Continue Watching (best resume across a title's sources) and
    /// the Downloaded titles. Fault-tolerant via `unifiedItems`.
    public func homeRails(resumeStore: ResumeStore, limit: Int = 30) async -> UnifiedRails {
        // Movies and shows aggregate concurrently (each already fans out in
        // parallel internally).
        async let moviesTask = unifiedItems(kind: .movie)
        async let showsTask = unifiedItems(kind: .show)
        let movies = await moviesTask
        let shows = await showsTask

        var continueWatching: [HomeFeed.ContinueWatchingEntry] = []
        for unified in movies + shows {
            var best: (item: MediaItem, resume: ResumePoint)?
            for source in unified.sources {
                guard let resume = await resumeStore.point(for: source.item.id) else { continue }
                if best == nil || Self.seconds(resume.position) > Self.seconds(best!.resume.position) {
                    best = (source.item, resume)
                }
            }
            if let best { continueWatching.append(.init(item: best.item, resume: best.resume)) }
        }

        let pool = movies + shows

        // Recently Added: newest library-add date first. When no source dates
        // its items, fall back to merge (source) order so Home isn't blank.
        let dated = pool.filter { $0.dateAdded != nil }
        let recentlyAdded: [UnifiedMediaItem]
        if dated.isEmpty {
            recentlyAdded = Array(Self.interleave(movies, shows).prefix(limit))
        } else {
            recentlyAdded = Array(
                dated.sorted { ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast) }
                    .prefix(limit)
            )
        }

        // Recently Released: newest original-release date first. No fallback —
        // an undated catalog simply hides this rail.
        let recentlyReleased = Array(
            pool.filter { $0.releaseDate != nil }
                .sorted { ($0.releaseDate ?? .distantPast) > ($1.releaseDate ?? .distantPast) }
                .prefix(limit)
        )

        return UnifiedRails(
            continueWatching: continueWatching,
            movies: Array(movies.prefix(limit)),
            shows: Array(shows.prefix(limit)),
            downloaded: pool.filter(\.isDownloaded),
            recentlyAdded: recentlyAdded,
            recentlyReleased: recentlyReleased,
            movieCount: movies.count,
            showCount: shows.count
        )
    }

    /// Round-robin two lists: a, b, a, b, … until both drain. Used for the
    /// Recently Added fallback so neither movies nor shows dominate.
    private static func interleave(
        _ a: [UnifiedMediaItem], _ b: [UnifiedMediaItem]
    ) -> [UnifiedMediaItem] {
        var result: [UnifiedMediaItem] = []
        var index = 0
        while index < a.count || index < b.count {
            if index < a.count { result.append(a[index]) }
            if index < b.count { result.append(b[index]) }
            index += 1
        }
        return result
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    // MARK: - Merge engine (pure, testable)

    public nonisolated static func merge(
        _ items: [MediaItem],
        downloaded: Set<MediaID> = [],
        serverNames: [MediaSourceID: String] = [:]
    ) -> [UnifiedMediaItem] {
        guard !items.isEmpty else { return [] }

        // 1. Union-find over items sharing any identity token.
        var parent = Array(0..<items.count)
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { parent[r] = parent[parent[r]]; r = parent[r] }
            return r
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        var tokenOwner: [String: Int] = [:]
        for (i, item) in items.enumerated() {
            for token in identityTokens(for: item) {
                if let j = tokenOwner[token] { union(i, j) } else { tokenOwner[token] = i }
            }
        }

        // 2. Group item indices by representative, preserving first-seen order.
        var groups: [Int: [Int]] = [:]
        var order: [Int] = []
        for i in items.indices {
            let root = find(i)
            if groups[root] == nil { order.append(root) }
            groups[root, default: []].append(i)
        }

        // 3. Build a UnifiedMediaItem per group.
        return order.map { root in
            let groupItems = groups[root]!.map { items[$0] }
            return makeUnified(groupItems, downloaded: downloaded, serverNames: serverNames)
        }
    }

    // MARK: - Identity

    /// Identity tokens for an item, strongest first. Any shared token merges two
    /// items.
    static func identityTokens(for item: MediaItem) -> [String] {
        var tokens: [String] = []
        if let v = item.guids.tmdb { tokens.append("tmdb:\(v)") }
        if let v = item.guids.imdb { tokens.append("imdb:\(v)") }
        if let v = item.guids.tvdb { tokens.append("tvdb:\(v)") }
        if tokens.isEmpty {
            if let year = item.year {
                tokens.append("ty:\(normalizedTitle(item.title))|\(year)")
            } else {
                // No id and no year → never merge: unique per source item.
                tokens.append("uniq:\(item.id.source.stableKey):\(item.id.rawValue)")
            }
        }
        return tokens
    }

    /// The canonical id for a unified group — the strongest external id shared,
    /// else the title+year token, else a unique token. Stable run-to-run.
    private static func canonicalID(for items: [MediaItem]) -> String {
        if let v = items.compactMap({ $0.guids.tmdb }).first { return "tmdb:\(v)" }
        if let v = items.compactMap({ $0.guids.imdb }).first { return "imdb:\(v)" }
        if let v = items.compactMap({ $0.guids.tvdb }).first { return "tvdb:\(v)" }
        if let first = items.first, let year = first.year {
            return "ty:\(normalizedTitle(first.title))|\(year)"
        }
        let first = items.first
        return "uniq:\(first?.id.source.stableKey ?? "?"):\(first?.id.rawValue ?? "?")"
    }

    /// Lowercased, alphanumerics-only — tolerant of punctuation / spacing for
    /// the title+year fallback.
    static func normalizedTitle(_ title: String) -> String {
        title.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
    }

    // MARK: - Assembly

    private static func makeUnified(
        _ items: [MediaItem],
        downloaded: Set<MediaID>,
        serverNames: [MediaSourceID: String]
    ) -> UnifiedMediaItem {
        var sources: [UnifiedSource] = []
        for item in items {
            if downloaded.contains(item.id) {
                sources.append(UnifiedSource(kind: .offline, item: item, serverName: nil, playable: true))
            }
            if let kind = MediaSourceKind(streaming: item.id.source) {
                sources.append(UnifiedSource(
                    kind: kind,
                    item: item,
                    serverName: serverNames[item.id.source],
                    playable: item.streamURL != nil
                ))
            }
        }
        sources.sort { $0.kind < $1.kind }

        // Representative metadata = the preferred (highest-priority) source's
        // item, falling back to the first item if nothing is playable.
        let lead = sources.first?.item ?? items[0]
        return UnifiedMediaItem(
            id: canonicalID(for: items),
            title: lead.title,
            year: lead.year,
            overview: lead.summary,
            posterURL: lead.posterURL,
            backdropURL: lead.backdropURL,
            type: lead.kind,
            sources: sources,
            genres: lead.genres,
            communityRating: lead.communityRating,
            releaseDate: lead.releaseDate,
            // Prefer any source that reports an add date (the lead's library may
            // not), so "Recently Added" still works when only one server dates it.
            dateAdded: items.compactMap(\.dateAdded).max() ?? lead.dateAdded
        )
    }
}
