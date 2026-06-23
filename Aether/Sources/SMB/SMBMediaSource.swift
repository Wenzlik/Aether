import Foundation
import os
import AetherCore

/// An SMB share as a `MediaSource` (#214). Lives in the app target (not
/// AetherCore) because it browses + plays through VLCKit, which only the app
/// target links.
///
/// There's no server catalog or metadata — just files. So it mirrors
/// `LocalMediaSource`: recursively walk the configured roots (depth- and
/// count-capped), run each filename through `TitleInference`, and surface the
/// result as flat movies + synthetic show containers (`show:<series>`) split
/// into "Movies" / "TV Shows" libraries. Playback is direct: `streamURL` is the
/// credential-free `smb://` URL, routed to VLCKit by `VideoEngineResolver`, with
/// credentials supplied as media options at play time (`vlcMediaOptions`).
/// Why an SMB download couldn't start (the transfer itself throws SMBClient's
/// own errors, which already read clearly).
enum SMBDownloadError: LocalizedError {
    case noStreamURL
    case badStreamURL
    var errorDescription: String? {
        switch self {
        case .noStreamURL: return "This item has no SMB file to download."
        case .badStreamURL: return "Couldn't read the SMB path for this item."
        }
    }
}

actor SMBMediaSource: CustomDownloadSource {
    nonisolated let id: MediaSourceID
    nonisolated let displayName: String
    /// Credentials for the player layer (DetailView reads this off the resolved
    /// source). Credential-free URLs + options is the auth model (#214).
    nonisolated let vlcMediaOptions: [String]

    private let connection: SMBConnection
    /// TMDb matcher — SMB files carry no artwork, so we enrich each inferred
    /// title with a poster / backdrop / overview (same as the Local Library).
    /// `nil` when no TMDb key is built in → titles stay text-only.
    private let tmdb: TMDbClient?
    /// Cached recursive listing — the walk is expensive (network round-trips),
    /// so it's done once per source instance and reused across libraries/items.
    private var cachedFiles: [SMBFile]?
    /// Last walk's match stats (TMDb-matched / total), for the Settings readout
    /// (#SMB info). `nil` until the library has been walked at least once.
    private var lastStats: (matched: Int, total: Int)?

    /// TMDb match summary from the most recent walk — `nil` if the SMB library
    /// hasn't been browsed yet this session (we don't kick off a walk just for
    /// the Settings readout). Surfaced under the SMB row in Settings.
    func matchSummary() -> (matched: Int, total: Int)? { lastStats }

    private static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "mov", "avi", "ts", "m2ts", "webm", "flv", "wmv",
        "mpg", "mpeg", "ogm", "3gp", "vob", "divx",
    ]
    private static let maxDepth = 4
    private static let maxFiles = 2000
    private static let log = Logger(subsystem: "cz.zmrhal.aether", category: "smb")

    init(connection: SMBConnection, tmdb: TMDbClient? = nil) {
        self.connection = connection
        self.tmdb = tmdb
        self.id = connection.sourceID
        self.displayName = connection.displayName
        self.vlcMediaOptions = connection.vlcMediaOptions
    }

    private struct SMBFile: Sendable {
        let url: URL
        let inference: TitleInference
        /// Share + the folders leading to the file (no filename) — the signal the
        /// folder-role classifier groups by (#481).
        let folderComponents: [String]
        var metadata: TMDbMetadata?
        /// Resolution / codec / HDR / audio parsed from the release filename
        /// (SMB has no probed stream metadata).
        var mediaInfo: MediaInfo?
        /// User's title/year correction (#213), keyed by this file's stream URL.
        /// Used for both the TMDb match key and the displayed title/year.
        var override: SMBMetadataStore.Override?
        /// Folder-role result (#481), filled after the walk. `nil` falls back to
        /// the per-filename inference (defensive — classification always runs).
        var classification: SMBFolderClassifier.Classification?
        /// Series-level correction the user made on the show (keyed by the show
        /// id), filled after classification. Drives the show title + the series'
        /// TMDb match, so fixing one show fixes every episode.
        var seriesOverride: SMBMetadataStore.Override?

        /// Movie vs episode — the folder role wins over the filename guess.
        var roleIsEpisode: Bool { classification?.isEpisode ?? inference.isEpisode }
        /// Key that groups a show's episodes (the series folder), stable across
        /// filename variations. Falls back to the inferred title.
        var seriesGroupKey: String { classification?.seriesKey ?? inference.title }
        /// Show display name: the user's series correction wins, then the series
        /// folder name (TMDb canonical title is applied separately when matched).
        var seriesDisplayName: String {
            if let t = seriesOverride?.title, !t.isEmpty { return t }
            return classification?.seriesName ?? inference.title
        }
        var seriesMatchYear: Int? { seriesOverride?.year }

        /// Title to match + display: the user's correction wins over inference.
        var effectiveTitle: String {
            if let t = override?.title, !t.isEmpty { return t }
            return inference.title
        }
        var effectiveYear: Int? { override?.year ?? inference.year }
    }

    private nonisolated var moviesLibraryID: Library.ID { .init(source: id, rawValue: "movies") }
    private nonisolated var showsLibraryID: Library.ID { .init(source: id, rawValue: "shows") }
    private static let showPrefix = "show:"
    private static let seasonPrefix = "season:"

    // MARK: - MediaSource

    func libraries() async throws -> [Library] {
        let files = await files()
        var libs: [Library] = []
        if files.contains(where: { !$0.roleIsEpisode }) {
            libs.append(Library(id: moviesLibraryID, title: "Movies", kind: .movie))
        }
        if files.contains(where: { $0.roleIsEpisode }) {
            libs.append(Library(id: showsLibraryID, title: "TV Shows", kind: .show))
        }
        return libs
    }

    func items(in library: Library.ID) async throws -> [MediaItem] {
        let files = await files()
        if library == moviesLibraryID {
            return files.filter { !$0.roleIsEpisode }
                .map { movieItem($0) }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        if library == showsLibraryID {
            // Group a show's episodes by their series folder (#481), not by the
            // per-filename title — so filename variance doesn't fragment a show.
            let episodes = files.filter { $0.roleIsEpisode }
            return Dictionary(grouping: episodes, by: { $0.seriesGroupKey })
                .map { showContainer(seriesKey: $0.key, episodes: $0.value) }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        return []
    }

    func children(of id: MediaID) async throws -> [MediaItem] {
        guard id.source == self.id else { return [] }
        let files = await files()
        // Show → seasons. The app's show body expects `children` to be seasons
        // (single-season shows then render their episodes inline). SMB has no
        // season layer of its own, so synthesise one by grouping episodes on
        // their season number (episodes with none fold into Season 1).
        if id.rawValue.hasPrefix(Self.showPrefix) {
            let seriesKey = String(id.rawValue.dropFirst(Self.showPrefix.count))
            let episodes = files.filter { $0.roleIsEpisode && $0.seriesGroupKey == seriesKey }
            let bySeason = Dictionary(grouping: episodes, by: { Self.effectiveSeason($0) })
            return bySeason.keys.sorted().map {
                seasonItem(seriesKey: seriesKey, season: $0, episodes: bySeason[$0] ?? [], showEpisodes: episodes)
            }
        }
        // Season → its episodes.
        if id.rawValue.hasPrefix(Self.seasonPrefix), let (season, seriesKey) = Self.parseSeasonID(id.rawValue) {
            let episodes = files.filter {
                $0.roleIsEpisode && $0.seriesGroupKey == seriesKey && Self.effectiveSeason($0) == season
            }
            return sortedEpisodes(episodes).map { episodeItem($0, parentID: id) }
        }
        return []
    }

    func item(for id: MediaID) async throws -> MediaItem? {
        guard id.source == self.id else { return nil }
        let files = await files()
        if id.rawValue.hasPrefix(Self.showPrefix) {
            let seriesKey = String(id.rawValue.dropFirst(Self.showPrefix.count))
            let episodes = files.filter { $0.roleIsEpisode && $0.seriesGroupKey == seriesKey }
            return episodes.isEmpty ? nil : showContainer(seriesKey: seriesKey, episodes: episodes)
        }
        if id.rawValue.hasPrefix(Self.seasonPrefix), let (season, seriesKey) = Self.parseSeasonID(id.rawValue) {
            let showEpisodes = files.filter { $0.roleIsEpisode && $0.seriesGroupKey == seriesKey }
            let seasonEpisodes = showEpisodes.filter { Self.effectiveSeason($0) == season }
            return seasonEpisodes.isEmpty ? nil
                : seasonItem(seriesKey: seriesKey, season: season, episodes: seasonEpisodes, showEpisodes: showEpisodes)
        }
        guard let file = files.first(where: { $0.url.absoluteString == id.rawValue }) else { return nil }
        return file.roleIsEpisode
            ? episodeItem(file, parentID: seasonID(seriesKey: file.seriesGroupKey, season: Self.effectiveSeason(file)))
            : movieItem(file)
    }

    // MARK: - Playback resolution (#213)

    /// Override the default so mp4/m4v files on an SMB share route through the
    /// localhost range proxy and land in AVPlayer — `smb://` can't be opened by
    /// AVFoundation at all. mkv / avi etc. still go to VLCKit (via the proxy URL
    /// in `DetailView.presentPlayer`; `resolvePlayback` is not called for those).
    func resolvePlayback(_ request: PlaybackRequest) async throws -> ResolvedPlayback {
        guard let url = request.directPlayURL else {
            throw PlaybackResolveError.noPlayableStream
        }
        guard url.scheme == "smb",
              let proxyURL = await SMBRangeProxy.shared.register(connection: connection, smbURL: url)
        else {
            return ResolvedPlayback(url: url, isServerTranscode: false)
        }
        return ResolvedPlayback(url: proxyURL, isServerTranscode: false)
    }

    // Downloads run through `CustomDownloadSource` (not URLSession — `smb://`
    // isn't an HTTP URL): the DownloadManager calls `performDownload` to stream
    // the file's bytes to disk via SMBClient. Always "original" — SMB is a raw
    // file share, no server transcode.
    nonisolated var supportsDownloads: Bool { true }

    nonisolated func downloadFileExtension(for item: MediaItem) -> String? {
        guard let ext = item.streamURL?.pathExtension, !ext.isEmpty else { return nil }
        return ext
    }

    func performDownload(
        of item: MediaItem,
        to destination: URL,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        guard let streamURL = item.streamURL else {
            throw SMBDownloadError.noStreamURL
        }
        let (share, path) = SMBSession.shareAndPath(from: streamURL)
        guard !share.isEmpty else { throw SMBDownloadError.badStreamURL }
        let session = SMBSession(connection: connection)
        try await session.download(share: share, path: path, to: destination, progress: progress)
        Self.log.info("SMB download complete: \(item.title, privacy: .public)")
    }

    // MARK: - Walk

    /// Coalesces concurrent `files()` callers onto one walk. `SMBMediaSource` is
    /// an actor and `files()` awaits a long walk, so without this the actor's
    /// reentrancy let every concurrent caller (Home / Library / Search / grid /
    /// audio-options) start its *own* walk while the first was still running — a
    /// stampede that re-scanned the share many times and hammered TMDb into a
    /// rate-limit (→ 0 posters). One walk, shared by all waiters.
    private var walkTask: Task<[SMBFile], Never>?

    private func files() async -> [SMBFile] {
        if let cachedFiles { return cachedFiles }
        if let walkTask { return await walkTask.value }
        let task = Task { await performWalk() }
        walkTask = task
        let result = await task.value
        cachedFiles = result
        walkTask = nil
        return result
    }

    private func performWalk() async -> [SMBFile] {
        let session = SMBSession(connection: connection)
        // Roots to scan: the configured ones (share + path), else every share at
        // the host. Native browse via the pure-Swift SMBClient (#213) — real
        // errors, no VLC. `SMBSession` owns the depth/count-capped BFS per share.
        var roots: [(share: String, path: String)] = connection.roots.map { SMBConnection.splitShareAndPath($0) }
        if roots.isEmpty {
            let shares = (try? await session.shares()) ?? []
            roots = shares.map { ($0, "/") }
        }
        // User title/year corrections, keyed by stream URL (#213).
        let overrides = await SMBMetadataStore.shared.allOverrides()
        var discovered: [SMBFile] = []
        for root in roots {
            let remaining = Self.maxFiles - discovered.count
            if remaining <= 0 { break }
            let entries = await session.walkVideos(
                share: root.share,
                basePath: root.path,
                maxDepth: Self.maxDepth,
                maxFiles: remaining,
                videoExtensions: Self.videoExtensions
            )
            for entry in entries {
                // Path components for TitleInference: the share + the folders
                // leading to the file (drop the filename), e.g. ["HD","Movies"].
                let pathComponents = [root.share] + entry.path.split(separator: "/").map(String.init).dropLast()
                let inference = TitleInference(filename: entry.name, pathComponents: Array(pathComponents))
                let mediaInfo = MediaInfo.fromFilename(entry.name, container: (entry.name as NSString).pathExtension)
                discovered.append(SMBFile(
                    url: entry.streamURL,
                    inference: inference,
                    folderComponents: Array(pathComponents),
                    mediaInfo: mediaInfo,
                    override: overrides[entry.streamURL.absoluteString]
                ))
            }
        }
        Self.log.info("SMB walk: \(discovered.count, privacy: .public) video files; TMDb configured=\(self.tmdb?.isConfigured ?? false, privacy: .public)")
        classifyFolderRoles(&discovered)
        // Attach any series-level correction (keyed by the show id) so the show
        // title + the series TMDb match reflect a fix made on the show (#213).
        for index in discovered.indices where discovered[index].roleIsEpisode {
            discovered[index].seriesOverride = overrides["\(Self.showPrefix)\(discovered[index].seriesGroupKey)"]
        }
        await enrichWithTMDb(&discovered)
        let matched = discovered.filter { $0.metadata != nil }.count
        Self.log.info("SMB TMDb: matched \(matched, privacy: .public)/\(discovered.count, privacy: .public) titles")
        lastStats = (matched: matched, total: discovered.count)
        return discovered   // `files()` owns caching
    }

    /// Tag each file with its folder role (#481): group a show's episodes by the
    /// series folder (stable across filename variations, so a series doesn't
    /// fragment into one-episode shows) and fold oddly-named files in a series
    /// folder in as episodes rather than leaking them into Movies.
    private nonisolated func classifyFolderRoles(_ files: inout [SMBFile]) {
        let entries = files.map {
            SMBFolderClassifier.Entry(folderComponents: $0.folderComponents, isEpisode: $0.inference.isEpisode)
        }
        let classifications = SMBFolderClassifier.classify(entries)
        for index in files.indices { files[index].classification = classifications[index] }
    }

    /// Attach TMDb posters/overview to each file (SMB has none). Matched once per
    /// distinct (title, year, kind) and reused — episodes of a show all match the
    /// series, so they share one lookup. Best-effort: no key / no match leaves
    /// the inferred title text-only.
    private func enrichWithTMDb(_ files: inout [SMBFile]) async {
        guard !files.isEmpty else { return }
        let store = SMBMetadataStore.shared
        let canMatch = tmdb?.isConfigured ?? false
        var attempted = 0
        var succeeded = 0
        var pendingMisses: [String] = []
        for index in files.indices {
            let file = files[index]
            // Episodes match the series by its folder name → one TMDb lookup
            // covers the whole show (consistent art). Movies match their own
            // title. A per-file title/year correction still wins (#213).
            let isEpisode = file.roleIsEpisode
            let title: String
            let year: Int?
            if isEpisode {
                // Series match keyed by the show's display name (series override
                // wins, else the folder name) → one lookup per show.
                title = file.seriesDisplayName
                year = file.seriesMatchYear
            } else {
                title = file.effectiveTitle
                year = file.effectiveYear
            }
            let key = SMBMetadataStore.key(title: title, year: year, isEpisode: isEpisode)
            switch await store.lookup(key) {
            case .hit(let metadata):
                files[index].metadata = metadata
            case .miss:
                continue   // tried before, no TMDb match → don't re-hit the network (battery)
            case .unknown:
                guard canMatch, let tmdb else { continue }   // no key yet → leave for a later browse
                attempted += 1
                if let match = await tmdb.match(title: title, year: year, isEpisode: isEpisode) {
                    await store.record(match, for: key)   // persist hits immediately
                    files[index].metadata = match
                    succeeded += 1
                } else {
                    pendingMisses.append(key)              // hold — decide below
                }
            }
        }
        // Only persist misses once we've proven the key actually works this pass
        // (≥1 hit). A wholesale 0% rate means a rate-limited / wrong key or no
        // network — NOT hundreds of genuinely-unmatchable files; caching those as
        // misses would poison the store so even a working key shows nothing until
        // a manual Re-match. Leaving them un-recorded lets the next browse retry.
        if succeeded > 0 || attempted == 0 {
            for key in pendingMisses { await store.record(nil, for: key) }
        } else if attempted > 0 {
            Self.log.error("SMB TMDb: 0/\(attempted, privacy: .public) matched — likely a rate-limited/invalid key or no network; not caching misses, will retry next browse.")
        }
    }

    /// Drop the cached walk + retry unmatched titles on the next browse — backs a
    /// "Re-match" / refresh action (the persistent store otherwise never retries
    /// a miss). Hits stay cached, so it's cheap.
    func invalidate() async {
        cachedFiles = nil
        lastStats = nil
        await SMBMetadataStore.shared.clearMisses()
        await SMBRangeProxy.shared.unregisterAll(connectionID: connection.id)
    }

    // MARK: - HTTP range proxy (#213/#347)

    /// Register an SMB file with the localhost range proxy and return an HTTP
    /// URL for VLCKit / AVPlayer.
    ///
    /// Called by `DetailView.presentPlayer` just before playback starts.
    /// Returns `nil` if the proxy server failed to bind — callers should then
    /// fall back to the raw `smb://` URL + `vlcMediaOptions`.
    func proxyURL(for smbURL: URL) async -> URL? {
        await SMBRangeProxy.shared.register(connection: connection, smbURL: smbURL)
    }

    /// The user's current title/year correction for an item (its stream URL),
    /// so the edit sheet can pre-fill. `nil` when uncorrected.
    func override(forItem itemID: MediaID) async -> SMBMetadataStore.Override? {
        await SMBMetadataStore.shared.override(forItem: itemID.rawValue)
    }

    /// Save the user's title/year correction for an SMB item (#213), then drop
    /// the cached walk so the next browse re-runs TitleInference with the
    /// correction → a new TMDb match key → a fresh poster lookup.
    func setOverride(_ override: SMBMetadataStore.Override?, forItem itemID: MediaID) async {
        await SMBMetadataStore.shared.setOverride(override, forItem: itemID.rawValue)
        cachedFiles = nil
        lastStats = nil
    }

    // MARK: - Mapping

    private nonisolated func showID(for seriesKey: String) -> MediaID {
        .init(source: id, rawValue: "\(Self.showPrefix)\(seriesKey)")
    }

    /// Synthetic season id: `season:<number>:<seriesKey>`. The number comes first
    /// so the series key (which can contain `:` / `/`) is the unambiguous tail.
    private nonisolated func seasonID(seriesKey: String, season: Int) -> MediaID {
        .init(source: id, rawValue: "\(Self.seasonPrefix)\(season):\(seriesKey)")
    }

    /// Parse `season:<number>:<seriesKey>` back into its parts.
    private nonisolated static func parseSeasonID(_ raw: String) -> (season: Int, seriesKey: String)? {
        let body = raw.dropFirst(seasonPrefix.count)
        guard let colon = body.firstIndex(of: ":"),
              let season = Int(body[..<colon]) else { return nil }
        return (season, String(body[body.index(after: colon)...]))
    }

    /// Episodes with no parsed season fold into Season 1 so they still appear.
    private nonisolated static func effectiveSeason(_ file: SMBFile) -> Int {
        file.inference.season ?? 1
    }

    private nonisolated func seasonItem(seriesKey: String, season: Int, episodes: [SMBFile], showEpisodes: [SMBFile]) -> MediaItem {
        // SMB has no per-season art — reuse the show's match poster/backdrop.
        let metadata = showEpisodes.compactMap(\.metadata).first
        return MediaItem(
            id: seasonID(seriesKey: seriesKey, season: season),
            title: "Season \(season)",
            kind: .season,
            posterURL: metadata?.posterURL,
            backdropURL: metadata?.backdropURL,
            seasonNumber: season,
            parentID: showID(for: seriesKey),
            episodeCount: episodes.count
        )
    }

    private nonisolated func movieItem(_ file: SMBFile) -> MediaItem {
        MediaItem(
            id: .init(source: id, rawValue: file.url.absoluteString),
            // Canonical TMDb title when matched, else the user's correction,
            // else the inferred one.
            title: file.metadata?.title ?? file.effectiveTitle,
            kind: .movie,
            year: file.metadata?.year ?? file.effectiveYear,
            summary: file.metadata?.overview,
            posterURL: file.metadata?.posterURL,
            backdropURL: file.metadata?.backdropURL,
            streamURL: file.url,
            mediaInfo: file.mediaInfo
        )
    }

    private nonisolated func episodeItem(_ file: SMBFile, parentID: MediaID) -> MediaItem {
        MediaItem(
            id: .init(source: id, rawValue: file.url.absoluteString),
            title: episodeDisplayTitle(file.inference),
            kind: .episode,
            year: file.inference.year,
            // The series' TMDb art (episodes share the show's poster/backdrop).
            posterURL: file.metadata?.posterURL,
            backdropURL: file.metadata?.backdropURL,
            streamURL: file.url,
            mediaInfo: file.mediaInfo,
            seriesTitle: file.seriesDisplayName,
            seasonNumber: Self.effectiveSeason(file),
            episodeNumber: file.inference.episode,
            parentID: parentID
        )
    }

    private nonisolated func showContainer(seriesKey: String, episodes: [SMBFile]) -> MediaItem {
        // Series art from the first episode that got a TMDb match; the title is
        // the canonical match, else the series folder name (#481).
        let metadata = episodes.compactMap(\.metadata).first
        let folderName = episodes.first?.seriesDisplayName ?? seriesKey
        return MediaItem(
            id: showID(for: seriesKey),
            title: metadata?.title ?? folderName,
            kind: .show,
            summary: metadata?.overview,
            posterURL: metadata?.posterURL,
            backdropURL: metadata?.backdropURL,
            episodeCount: episodes.count
        )
    }

    private nonisolated func episodeDisplayTitle(_ inference: TitleInference) -> String {
        if let season = inference.season, let episode = inference.episode {
            return "S\(season)E\(episode)"
        }
        return inference.title
    }

    private nonisolated func sortedEpisodes(_ files: [SMBFile]) -> [SMBFile] {
        files.sorted {
            ($0.inference.season ?? 0, $0.inference.episode ?? 0)
                < ($1.inference.season ?? 0, $1.inference.episode ?? 0)
        }
    }
}
