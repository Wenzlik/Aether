import Foundation
import AetherCore

/// A **local library** built by scanning folders the user picks (on the Mac or
/// a mounted network share). Walks the folders for video files, parses each
/// filename into a movie or a show episode (`S01E02`), and exposes them through
/// the `MediaSource` protocol so they flow into `UnifiedLibrary` alongside
/// Plex/Jellyfin and play through the same libmpv player (the file URL is the
/// stream URL — no server, no transcode).
///
/// Scan results are cached; a new instance is built whenever the folder set
/// changes (see `MacSession`).
actor LocalFolderSource: MediaSource {
    nonisolated let id: MediaSourceID = .local
    nonisolated let displayName = "Local Library"

    private let folders: [URL]
    /// Per-folder content hint (Movies / TV / Both), keyed by the configured
    /// folder URL. Missing → `.both` (auto-detect), so folders added before this
    /// existed keep the original heuristic. Fed to `SMBFolderClassifier`.
    private let content: [URL: SMBRootContent]
    private let tmdb: TMDbClient?
    private var scanned: Scan?

    private static let overridesKey = "localLibrary.tmdbOverrides"

    private static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "mov", "avi", "ts", "m2ts", "webm", "flv", "wmv", "mpg", "mpeg"
    ]
    private nonisolated var moviesLibraryID: Library.ID { .init(source: id, rawValue: "movies") }
    private nonisolated var showsLibraryID: Library.ID { .init(source: id, rawValue: "shows") }
    private static let showPrefix = "show:"
    private static let seasonPrefix = "season:"

    /// `tmdb` (when a TMDb key is configured) enriches scanned movies/shows with
    /// posters, backdrops, and overviews — otherwise they show title-only cards.
    init(folders: [URL], content: [URL: SMBRootContent] = [:], tmdb: TMDbClient? = nil) {
        self.folders = folders
        self.content = content
        self.tmdb = tmdb
    }

    // MARK: MediaSource

    /// Movie + show counts after scanning — for the Settings status line.
    func counts() async -> (movies: Int, shows: Int) {
        let s = await scan()
        return (s.movies.count, s.shows.count)
    }

    func libraries() async throws -> [Library] {
        let scan = await scan()
        var libs: [Library] = []
        if !scan.movies.isEmpty { libs.append(Library(id: moviesLibraryID, title: "Movies", kind: .movie)) }
        if !scan.episodesByShow.isEmpty { libs.append(Library(id: showsLibraryID, title: "TV Shows", kind: .show)) }
        return libs
    }

    func items(in library: Library.ID) async throws -> [MediaItem] {
        let scan = await scan()
        if library == moviesLibraryID { return scan.movies }
        if library == showsLibraryID { return scan.shows }
        return []
    }

    func children(of id: MediaID) async throws -> [MediaItem] {
        let scan = await scan()
        // Show → season containers (one per distinct season number).
        if id.rawValue.hasPrefix(Self.showPrefix) {
            let series = String(id.rawValue.dropFirst(Self.showPrefix.count))
            let episodes = scan.episodesByShow[series] ?? []
            let seasons = Set(episodes.map { $0.seasonNumber ?? 0 }).sorted()
            return seasons.map { season in seasonItem(series: series, season: season) }
        }
        // Season → its episodes.
        if let (series, season) = Self.parseSeasonID(id.rawValue) {
            return (scan.episodesByShow[series] ?? [])
                .filter { ($0.seasonNumber ?? 0) == season }
                .sorted { ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0) }
        }
        return []
    }

    func item(for id: MediaID) async throws -> MediaItem? {
        let scan = await scan()
        if let m = scan.byID[id.rawValue] { return m }
        if id.rawValue.hasPrefix(Self.showPrefix) { return scan.shows.first { $0.id == id } }
        if let (series, season) = Self.parseSeasonID(id.rawValue) { return seasonItem(series: series, season: season) }
        return nil
    }

    private nonisolated func seasonItem(series: String, season: Int) -> MediaItem {
        MediaItem(
            id: .init(source: id, rawValue: "\(Self.seasonPrefix)\(season):\(series)"),
            title: season == 0 ? "Specials" : "Season \(season)",
            kind: .season, seasonNumber: season,
            parentID: .init(source: id, rawValue: Self.showPrefix + series)
        )
    }

    /// `season:2:Breaking Bad` → ("Breaking Bad", 2).
    private static func parseSeasonID(_ raw: String) -> (series: String, season: Int)? {
        guard raw.hasPrefix(seasonPrefix) else { return nil }
        let rest = raw.dropFirst(seasonPrefix.count)
        guard let colon = rest.firstIndex(of: ":"), let season = Int(rest[..<colon]) else { return nil }
        return (String(rest[rest.index(after: colon)...]), season)
    }

    func resolvePlayback(_ request: PlaybackRequest) async throws -> ResolvedPlayback {
        // The item id *is* the file path — play it directly, no transcode.
        ResolvedPlayback(url: URL(fileURLWithPath: request.itemID.rawValue), isServerTranscode: false)
    }

    // MARK: Scanning

    private struct Scan {
        var movies: [MediaItem] = []
        var shows: [MediaItem] = []
        /// Episodes keyed by their **series folder** (the classifier's seriesKey),
        /// stable across filename variations — not by the per-filename title.
        var episodesByShow: [String: [MediaItem]] = [:]
        var byID: [String: MediaItem] = [:]
    }

    private struct RawMovie { let title: String; let year: Int?; let url: URL; let path: String }

    /// One enumerated video file plus the signals the folder-role classifier
    /// needs (the folder path leading to it + a per-filename episode guess +
    /// the configured root's content choice).
    private struct RawFile {
        let url: URL, path: String, stem: String
        let episode: Episode?
        let folderComponents: [String]
        let content: SMBRootContent
    }

    private func scan() async -> Scan {
        if let scanned { return scanned }
        var result = Scan()
        let fm = FileManager.default

        // First pass — enumerate every video file under each folder.
        var raws: [RawFile] = []
        for folder in folders {
            let rootContent = content[folder] ?? .both
            let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                  options: [.skipsHiddenFiles])
            while let url = e?.nextObject() as? URL {
                guard Self.videoExtensions.contains(url.pathExtension.lowercased()) else { continue }
                let stem = url.deletingPathExtension().lastPathComponent
                raws.append(RawFile(
                    url: url, path: url.path, stem: stem,
                    episode: Self.parseEpisode(stem),
                    folderComponents: url.deletingLastPathComponent().pathComponents,
                    content: rootContent
                ))
            }
        }

        // Folder-role classification (#481, shared AetherCore logic — parity with
        // iOS SMB): the folder decides movie-vs-episode, so a series folder groups
        // every file into one show and a movies folder never fragments into bogus
        // shows. `.both` auto-detects; `.movies`/`.series` force the role.
        let roles = SMBFolderClassifier.classify(raws.map {
            .init(folderComponents: $0.folderComponents, isEpisode: $0.episode != nil, content: $0.content)
        })

        var rawMovies: [RawMovie] = []
        var showNames: [String: String] = [:]   // seriesKey → display name
        for (raw, role) in zip(raws, roles) {
            if role.isEpisode {
                let seriesKey = role.seriesKey ?? raw.episode?.series ?? raw.stem
                let display = role.seriesName ?? raw.episode?.series ?? seriesKey
                let epTitle = raw.episode?.title ?? ""
                let item = MediaItem(
                    id: .init(source: id, rawValue: raw.path),
                    title: epTitle.isEmpty ? raw.stem : epTitle,
                    kind: .episode, streamURL: raw.url,
                    seriesTitle: display,
                    seasonNumber: raw.episode?.season ?? 1,   // forced/unparsed → Season 1
                    episodeNumber: raw.episode?.episode
                )
                result.episodesByShow[seriesKey, default: []].append(item)
                result.byID[raw.path] = item
                showNames[seriesKey] = display
            } else {
                let movie = Self.parseMovie(raw.stem)
                rawMovies.append(RawMovie(title: movie.title, year: movie.year, url: raw.url, path: raw.path))
            }
        }

        // Enrich movies + shows with TMDb (posters/backdrops/overviews) when a
        // key is configured, capped concurrency so a big library doesn't fire
        // hundreds of requests at once.
        result.movies = await matched(rawMovies.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        })
        for m in result.movies { result.byID[m.id.rawValue] = m }

        result.shows = await matchedShows(showNames)

        scanned = result
        return result
    }

    /// Build movie `MediaItem`s, looking up TMDb metadata in batches of 8.
    private func matched(_ raws: [RawMovie]) async -> [MediaItem] {
        let overrides = Self.loadOverrides()
        var out: [MediaItem] = []
        for chunk in raws.chunked(8) {
            let items = await withTaskGroup(of: MediaItem.self) { group in
                for r in chunk {
                    group.addTask { [tmdb, id] in
                        let meta: TMDbMetadata?
                        if let override = overrides[r.path] {
                            meta = override
                        } else {
                            meta = await tmdb?.match(title: r.title, year: r.year, isEpisode: false)
                        }
                        return MediaItem(
                            id: .init(source: id, rawValue: r.path),
                            title: meta?.title ?? r.title,
                            kind: .movie,
                            year: meta?.year ?? r.year,
                            summary: meta?.overview,
                            posterURL: meta?.posterURL,
                            backdropURL: meta?.backdropURL,
                            streamURL: r.url,
                            mediaInfo: Self.buildMediaInfo(url: r.url, path: r.path),
                            guids: MediaGuids(tmdb: meta.map { "\($0.tmdbID)" }),
                            communityRating: meta?.rating
                        )
                    }
                }
                var acc: [MediaItem] = []
                for await item in group { acc.append(item) }
                return acc
            }
            out.append(contentsOf: items)
        }
        return out.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Update in-memory scan cache and persist override so it survives rescans.
    func applyTMDbOverride(_ meta: TMDbMetadata, for id: MediaID) {
        guard var scan = scanned, let existing = scan.byID[id.rawValue] else { return }
        let updated = MediaItem(
            id: existing.id,
            title: meta.title,
            kind: existing.kind,
            year: meta.year ?? existing.year,
            summary: meta.overview,
            posterURL: meta.posterURL,
            backdropURL: meta.backdropURL,
            streamURL: existing.streamURL,
            mediaInfo: existing.mediaInfo,
            guids: MediaGuids(tmdb: "\(meta.tmdbID)"),
            communityRating: meta.rating
        )
        scan.byID[id.rawValue] = updated
        scan.movies = scan.movies.map { $0.id == id ? updated : $0 }
        scanned = scan
        var overrides = Self.loadOverrides()
        overrides[id.rawValue] = meta
        Self.saveOverrides(overrides)
    }

    private static func buildMediaInfo(url: URL, path: String) -> MediaInfo? {
        let ext = url.pathExtension.lowercased()
        let fromName = MediaInfo.fromFilename(url.lastPathComponent, container: ext.isEmpty ? nil : ext)
        let size: Int64? = {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let v = attrs[.size] else { return nil }
            if let i = v as? Int64 { return i }
            if let n = v as? NSNumber { return n.int64Value }
            return nil
        }()
        guard fromName != nil || size != nil else { return nil }
        return MediaInfo(
            videoCodec: fromName?.videoCodec,
            audioCodec: fromName?.audioCodec,
            audioChannels: fromName?.audioChannels,
            videoResolution: fromName?.videoResolution,
            bitrateKbps: fromName?.bitrateKbps,
            isHDR: fromName?.isHDR ?? false,
            isDolbyVision: fromName?.isDolbyVision ?? false,
            container: fromName?.container ?? (ext.isEmpty ? nil : ext),
            fileSizeBytes: size
        )
    }

    private static func loadOverrides() -> [String: TMDbMetadata] {
        guard let data = UserDefaults.standard.data(forKey: overridesKey),
              let decoded = try? JSONDecoder().decode([String: TMDbMetadata].self, from: data) else { return [:] }
        return decoded
    }

    private static func saveOverrides(_ overrides: [String: TMDbMetadata]) {
        if let data = try? JSONEncoder().encode(overrides) {
            UserDefaults.standard.set(data, forKey: overridesKey)
        }
    }

    /// One show container per series folder, with a TMDb (TV) poster when
    /// matched. Keyed by the classifier's seriesKey (stable), matched + titled by
    /// the folder display name.
    private func matchedShows(_ shows: [String: String]) async -> [MediaItem] {
        var out: [MediaItem] = []
        let entries = shows.sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
        for chunk in entries.chunked(8) {
            let items = await withTaskGroup(of: MediaItem.self) { group in
                for (key, name) in chunk {
                    group.addTask { [tmdb, id] in
                        let meta = await tmdb?.match(title: name, year: nil, isEpisode: true)
                        return MediaItem(
                            id: .init(source: id, rawValue: Self.showPrefix + key),
                            title: name, kind: .show,
                            summary: meta?.overview, posterURL: meta?.posterURL,
                            backdropURL: meta?.backdropURL
                        )
                    }
                }
                var acc: [MediaItem] = []
                for await item in group { acc.append(item) }
                return acc
            }
            out.append(contentsOf: items)
        }
        return out.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    // MARK: Filename parsing

    private struct Episode { let series: String; let season: Int; let episode: Int; let title: String }

    /// Parse `Show.Name.S01E02.Episode.Title` → series/season/episode/title.
    private static func parseEpisode(_ stem: String) -> Episode? {
        guard let m = try? NSRegularExpression(pattern: "^(.*?)[ ._-]*[sS](\\d{1,2})[ ._-]*[eE](\\d{1,2})(.*)$"),
              let match = m.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
              let seriesR = Range(match.range(at: 1), in: stem),
              let seasonR = Range(match.range(at: 2), in: stem),
              let episodeR = Range(match.range(at: 3), in: stem) else { return nil }
        let series = clean(String(stem[seriesR]))
        let season = Int(stem[seasonR]) ?? 0
        let episode = Int(stem[episodeR]) ?? 0
        var title = ""
        if let titleR = Range(match.range(at: 4), in: stem) { title = clean(String(stem[titleR])) }
        guard !series.isEmpty else { return nil }
        return Episode(series: series, season: season, episode: episode, title: title)
    }

    /// Parse `Movie.Name.2021.1080p…` → title + year.
    private static func parseMovie(_ stem: String) -> (title: String, year: Int?) {
        if let m = try? NSRegularExpression(pattern: "^(.*?)[ ._(]+((?:19|20)\\d{2})\\b"),
           let match = m.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
           let titleR = Range(match.range(at: 1), in: stem),
           let yearR = Range(match.range(at: 2), in: stem) {
            let title = clean(String(stem[titleR]))
            if !title.isEmpty { return (title, Int(stem[yearR])) }
        }
        return (clean(stem), nil)
    }

    /// Turn `Some.Movie_Name` separators into spaces and tidy whitespace.
    fileprivate static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "  ", with: " ")
    }
}

private extension Array {
    /// Split into sub-arrays of at most `size` — used to cap TMDb match concurrency.
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
