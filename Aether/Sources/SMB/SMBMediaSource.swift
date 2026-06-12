import Foundation
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
    /// Cached recursive listing — the walk is expensive (network round-trips),
    /// so it's done once per source instance and reused across libraries/items.
    private var cachedFiles: [SMBFile]?

    private static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "mov", "avi", "ts", "m2ts", "webm", "flv", "wmv",
        "mpg", "mpeg", "ogm", "3gp", "vob", "divx",
    ]
    private static let maxDepth = 4
    private static let maxFiles = 2000

    init(connection: SMBConnection) {
        self.connection = connection
        self.id = connection.sourceID
        self.displayName = connection.displayName
        self.vlcMediaOptions = connection.vlcMediaOptions
    }

    private struct SMBFile: Sendable {
        let url: URL
        let inference: TitleInference
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
                discovered.append(SMBFile(url: entry.streamURL, inference: inference))
            }
        }
        cachedFiles = discovered
        return discovered
    }

    // MARK: - Mapping

    private nonisolated func showID(for series: String) -> MediaID {
        .init(source: id, rawValue: "\(Self.showPrefix)\(series)")
    }

    private nonisolated func movieItem(_ file: SMBFile) -> MediaItem {
        MediaItem(
            id: .init(source: id, rawValue: file.url.absoluteString),
            title: file.inference.title,
            kind: .movie,
            year: file.inference.year,
            streamURL: file.url
        )
    }

    private nonisolated func episodeItem(_ file: SMBFile, showID: MediaID) -> MediaItem {
        MediaItem(
            id: .init(source: id, rawValue: file.url.absoluteString),
            title: episodeDisplayTitle(file.inference),
            kind: .episode,
            year: file.inference.year,
            streamURL: file.url,
            seriesTitle: file.inference.title,
            seasonNumber: file.inference.season,
            episodeNumber: file.inference.episode,
            parentID: showID
        )
    }

    private nonisolated func showContainer(series: String, episodes: [SMBFile]) -> MediaItem {
        MediaItem(
            id: showID(for: series),
            title: series,
            kind: .show,
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
