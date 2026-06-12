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
/// credential-free `smb://` URL, routed to VLCKit by `PlaybackEngine`, with
/// credentials supplied as media options at play time (`vlcMediaOptions`).
actor SMBMediaSource: MediaSource {
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
        var metadata: TMDbMetadata?
        /// Resolution / codec / HDR / audio parsed from the release filename
        /// (SMB has no probed stream metadata).
        var mediaInfo: MediaInfo?
    }

    private nonisolated var moviesLibraryID: Library.ID { .init(source: id, rawValue: "movies") }
    private nonisolated var showsLibraryID: Library.ID { .init(source: id, rawValue: "shows") }
    private static let showPrefix = "show:"

    // MARK: - MediaSource

    func libraries() async throws -> [Library] {
        let files = await files()
        var libs: [Library] = []
        if files.contains(where: { !$0.inference.isEpisode }) {
            libs.append(Library(id: moviesLibraryID, title: "Movies", kind: .movie))
        }
        if files.contains(where: { $0.inference.isEpisode }) {
            libs.append(Library(id: showsLibraryID, title: "TV Shows", kind: .show))
        }
        return libs
    }

    func items(in library: Library.ID) async throws -> [MediaItem] {
        let files = await files()
        if library == moviesLibraryID {
            return files.filter { !$0.inference.isEpisode }
                .map { movieItem($0) }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        if library == showsLibraryID {
            let episodes = files.filter { $0.inference.isEpisode }
            return Dictionary(grouping: episodes, by: { $0.inference.title })
                .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
                .map { showContainer(series: $0.key, episodes: $0.value) }
        }
        return []
    }

    func children(of id: MediaID) async throws -> [MediaItem] {
        guard id.source == self.id, id.rawValue.hasPrefix(Self.showPrefix) else { return [] }
        let series = String(id.rawValue.dropFirst(Self.showPrefix.count))
        let episodes = await files().filter { $0.inference.isEpisode && $0.inference.title == series }
        return sortedEpisodes(episodes).map { episodeItem($0, showID: id) }
    }

    func item(for id: MediaID) async throws -> MediaItem? {
        guard id.source == self.id else { return nil }
        if id.rawValue.hasPrefix(Self.showPrefix) {
            let series = String(id.rawValue.dropFirst(Self.showPrefix.count))
            let episodes = await files().filter { $0.inference.isEpisode && $0.inference.title == series }
            return episodes.isEmpty ? nil : showContainer(series: series, episodes: episodes)
        }
        guard let file = await files().first(where: { $0.url.absoluteString == id.rawValue }) else { return nil }
        return file.inference.isEpisode
            ? episodeItem(file, showID: showID(for: file.inference.title))
            : movieItem(file)
    }

    // `resolvePlayback` uses the protocol default → returns `streamURL` for
    // direct play. PlaybackEngine routes the smb:// URL to VLCKit.
    nonisolated var supportsDownloads: Bool { false }

    // MARK: - Walk

    private func files() async -> [SMBFile] {
        if let cachedFiles { return cachedFiles }
        let session = SMBSession(connection: connection)
        // Roots to scan: the configured ones (share + path), else every share at
        // the host. Native browse via the pure-Swift SMBClient (#213) — real
        // errors, no VLC. `SMBSession` owns the depth/count-capped BFS per share.
        var roots: [(share: String, path: String)] = connection.roots.map { SMBConnection.splitShareAndPath($0) }
        if roots.isEmpty {
            let shares = (try? await session.shares()) ?? []
            roots = shares.map { ($0, "/") }
        }
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
                discovered.append(SMBFile(url: entry.streamURL, inference: inference, mediaInfo: mediaInfo))
            }
        }
        Self.log.info("SMB walk: \(discovered.count, privacy: .public) video files; TMDb configured=\(self.tmdb?.isConfigured ?? false, privacy: .public)")
        await enrichWithTMDb(&discovered)
        let matched = discovered.filter { $0.metadata != nil }.count
        Self.log.info("SMB TMDb: matched \(matched, privacy: .public)/\(discovered.count, privacy: .public) titles")
        cachedFiles = discovered
        return discovered
    }

    /// Attach TMDb posters/overview to each file (SMB has none). Matched once per
    /// distinct (title, year, kind) and reused — episodes of a show all match the
    /// series, so they share one lookup. Best-effort: no key / no match leaves
    /// the inferred title text-only.
    private func enrichWithTMDb(_ files: inout [SMBFile]) async {
        guard let tmdb, tmdb.isConfigured, !files.isEmpty else { return }
        var cache: [String: TMDbMetadata?] = [:]
        for index in files.indices {
            let inference = files[index].inference
            let key = "\(inference.isEpisode ? "tv" : "movie")|\(inference.title.lowercased())|\(inference.year.map(String.init) ?? "")"
            if let cached = cache[key] {
                files[index].metadata = cached
            } else {
                let match = await tmdb.match(title: inference.title, year: inference.year, isEpisode: inference.isEpisode)
                cache[key] = match
                files[index].metadata = match
            }
        }
    }

    // MARK: - Mapping

    private nonisolated func showID(for series: String) -> MediaID {
        .init(source: id, rawValue: "\(Self.showPrefix)\(series)")
    }

    private nonisolated func movieItem(_ file: SMBFile) -> MediaItem {
        MediaItem(
            id: .init(source: id, rawValue: file.url.absoluteString),
            // Canonical TMDb title when matched, else the inferred one.
            title: file.metadata?.title ?? file.inference.title,
            kind: .movie,
            year: file.metadata?.year ?? file.inference.year,
            summary: file.metadata?.overview,
            posterURL: file.metadata?.posterURL,
            backdropURL: file.metadata?.backdropURL,
            streamURL: file.url,
            mediaInfo: file.mediaInfo
        )
    }

    private nonisolated func episodeItem(_ file: SMBFile, showID: MediaID) -> MediaItem {
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
            seriesTitle: file.inference.title,
            seasonNumber: file.inference.season,
            episodeNumber: file.inference.episode,
            parentID: showID
        )
    }

    private nonisolated func showContainer(series: String, episodes: [SMBFile]) -> MediaItem {
        // Series art from the first episode that got a TMDb match.
        let metadata = episodes.compactMap(\.metadata).first
        return MediaItem(
            id: showID(for: series),
            title: metadata?.title ?? series,
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
