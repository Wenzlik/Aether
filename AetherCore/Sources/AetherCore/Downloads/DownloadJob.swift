import Foundation

/// A persistent record of "the user asked Aether to download this item."
///
/// Outlives the playback context: even after Detail is dismissed and the app
/// is suspended, the job survives in `DownloadStore` so the user can return
/// to Library and see "Downloaded" / "47%" / "Failed" without re-querying the
/// source. The metadata snapshot (`title` / `posterURL`) is captured at queue
/// time so an offline Library can render a poster card for the download
/// even when the server is unreachable.
public struct DownloadJob: Sendable, Hashable, Codable, Identifiable {
    /// Job-local identifier — `URLSessionTask.taskDescription` carries this
    /// stringified, which is how the URLSession delegate maps incoming
    /// progress / completion events back to a job.
    public let id: UUID

    /// The original `MediaID` from the source (Plex `ratingKey` etc.).
    /// Lookups from UI go MediaID → DownloadJob via the store, so a Plex
    /// item knows whether it's downloaded without round-tripping the
    /// server.
    public let mediaID: MediaID

    /// Snapshot of the title at queue time. The server might rename the
    /// item later (rare); the downloaded copy keeps the name the user
    /// queued under so an offline library doesn't show empty cards.
    public let title: String

    /// Snapshot of the poster URL — drives the Library rail's poster card
    /// when offline. Tokenised at the source layer (already includes
    /// auth) so it still loads while the user is signed-in to that source.
    public let posterURL: URL?

    /// Filename (relative to the downloads directory) of the poster image
    /// persisted to disk at enqueue time. Lets an offline card render its
    /// artwork from a local file when the server is unreachable *or* the
    /// token has expired — the `posterURL` snapshot can't survive either.
    /// Relative (not absolute) so it stays valid across relaunches even when
    /// iOS reassigns the app-container path. `nil` until the fetch lands (or
    /// for jobs recorded before this field existed). Resolve via
    /// `localPosterURL` / prefer the local copy via `displayPosterURL`.
    public let localPosterPath: String?

    /// Whether this download is a movie or an episode. Lets the offline
    /// surfaces decide which display format to use without re-fetching
    /// metadata.
    public let kind: MediaItem.Kind

    /// For episodes: the parent series title at enqueue time. Captured
    /// so Storage rows can render "Breaking Bad · S1E1 · Pilot" even
    /// when the source is unreachable.
    public let seriesTitle: String?

    /// For episodes: parent season number.
    public let seasonNumber: Int?

    /// For episodes: this episode's number within its season.
    public let episodeNumber: Int?

    /// User's quality choice at queue time. Stored so we can re-issue the
    /// download with the same parameters after a Retry, and so the
    /// Storage section can later report "Inception · 8 Mbps · 1.4 GB".
    public let quality: PlaybackQuality

    /// The resolved download URL captured at enqueue time. Persisted so a
    /// download can be **restarted from scratch** after relaunch when
    /// URLSession's resume data is gone (RAM evicted / never produced) —
    /// without needing a live `MediaSource` to re-resolve it. `nil` for jobs
    /// recorded before this field existed (they fall back to Retry-from-Detail).
    public let sourceURL: URL?

    /// `Date` the job was first recorded. Used for stable sort order in
    /// the Library "Downloaded" rail (newest first).
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        mediaID: MediaID,
        title: String,
        posterURL: URL? = nil,
        localPosterPath: String? = nil,
        kind: MediaItem.Kind = .movie,
        seriesTitle: String? = nil,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        quality: PlaybackQuality,
        sourceURL: URL? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.mediaID = mediaID
        self.title = title
        self.posterURL = posterURL
        self.localPosterPath = localPosterPath
        self.kind = kind
        self.seriesTitle = seriesTitle
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.quality = quality
        self.sourceURL = sourceURL
        self.createdAt = createdAt
    }

    /// Copy carrying the resolved download URL, set once the source resolves
    /// it (the job is recorded immediately for instant UI feedback, before the
    /// URL is known). Same `id`, so re-recording replaces in place.
    public func withSourceURL(_ url: URL?) -> DownloadJob {
        DownloadJob(
            id: id,
            mediaID: mediaID,
            title: title,
            posterURL: posterURL,
            localPosterPath: localPosterPath,
            kind: kind,
            seriesTitle: seriesTitle,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            quality: quality,
            sourceURL: url,
            createdAt: createdAt
        )
    }

    /// Copy carrying the persisted local poster filename, set once the poster
    /// fetch (kicked off at enqueue) lands. Same `id`, so re-recording replaces
    /// in place — and carries every other field forward unchanged.
    public func withLocalPosterPath(_ path: String?) -> DownloadJob {
        DownloadJob(
            id: id,
            mediaID: mediaID,
            title: title,
            posterURL: posterURL,
            localPosterPath: path,
            kind: kind,
            seriesTitle: seriesTitle,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            quality: quality,
            sourceURL: sourceURL,
            createdAt: createdAt
        )
    }

    /// The on-disk poster URL, resolved against the downloads directory — but
    /// only when the file actually exists (the fetch may still be in flight,
    /// or have failed). `nil` otherwise.
    public var localPosterURL: URL? {
        guard let localPosterPath else { return nil }
        let url = DownloadManager.defaultDownloadsDirectory().appendingPathComponent(localPosterPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The poster URL an offline-aware card should load: the persisted local
    /// copy first (works with no network and after the token expires), falling
    /// back to the server snapshot.
    public var displayPosterURL: URL? {
        localPosterURL ?? posterURL
    }

    /// Same `displayTitle` semantics as `MediaItem`, but resolved from
    /// the snapshot stored on this job. Used by Storage rows and the
    /// Library "Downloaded" rail when the live `MediaItem` may not be
    /// loaded (offline / source disconnected).
    public var displayTitle: String {
        guard kind == .episode else { return title }
        let episodeCode: String? = {
            guard let seasonNumber, let episodeNumber else { return nil }
            return "S\(seasonNumber)E\(episodeNumber)"
        }()
        let parts: [String] = [seriesTitle, episodeCode, title].compactMap { $0 }
        return parts.joined(separator: " · ")
    }
}

extension MediaItem.Kind: Codable {}

// MARK: - MediaID Codable conformance

// `MediaID` and `MediaSourceID` aren't Codable in the model layer (they don't
// need to be for normal source operations). The download persistence layer
// is the one place we cross the line — so the conformance lives here, next
// to the persisted shape that needs it. Keeps the model boundary clean and
// the persistence-only behaviour visible from the file that uses it.

extension MediaID: Codable {
    private enum CodingKeys: String, CodingKey {
        case source, rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let source = try container.decode(MediaSourceID.self, forKey: .source)
        let rawValue = try container.decode(String.self, forKey: .rawValue)
        self.init(source: source, rawValue: rawValue)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encode(rawValue, forKey: .rawValue)
    }
}

extension MediaSourceID: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, parameter
    }

    /// `kind` is the discriminator, `parameter` carries the associated
    /// value (server id / host). Two-key shape so we don't bake the enum's
    /// in-memory layout into the persistence format.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        let parameter = try container.decodeIfPresent(String.self, forKey: .parameter)
        switch kind {
        case "mock":
            self = .mock
        case "plex":
            guard let parameter else {
                throw DecodingError.dataCorruptedError(
                    forKey: .parameter, in: container,
                    debugDescription: "plex source missing serverID"
                )
            }
            self = .plex(serverID: parameter)
        case "jellyfin":
            guard let parameter else {
                throw DecodingError.dataCorruptedError(
                    forKey: .parameter, in: container,
                    debugDescription: "jellyfin source missing serverID"
                )
            }
            self = .jellyfin(serverID: parameter)
        case "emby":
            guard let parameter else {
                throw DecodingError.dataCorruptedError(
                    forKey: .parameter, in: container,
                    debugDescription: "emby source missing serverID"
                )
            }
            self = .emby(serverID: parameter)
        case "smb":
            guard let parameter else {
                throw DecodingError.dataCorruptedError(
                    forKey: .parameter, in: container,
                    debugDescription: "smb source missing id"
                )
            }
            self = .smb(id: parameter)
        case "dlna":
            guard let parameter else {
                throw DecodingError.dataCorruptedError(
                    forKey: .parameter, in: container,
                    debugDescription: "dlna source missing udn"
                )
            }
            self = .dlna(udn: parameter)
        case "local":
            self = .local
        case "external":
            guard let parameter else {
                throw DecodingError.dataCorruptedError(
                    forKey: .parameter, in: container,
                    debugDescription: "external source missing id"
                )
            }
            self = .external(id: parameter)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container,
                debugDescription: "unknown source kind \"\(kind)\""
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .mock:
            try container.encode("mock", forKey: .kind)
        case .plex(let serverID):
            try container.encode("plex", forKey: .kind)
            try container.encode(serverID, forKey: .parameter)
        case .jellyfin(let serverID):
            try container.encode("jellyfin", forKey: .kind)
            try container.encode(serverID, forKey: .parameter)
        case .emby(let serverID):
            try container.encode("emby", forKey: .kind)
            try container.encode(serverID, forKey: .parameter)
        case .smb(let id):
            try container.encode("smb", forKey: .kind)
            try container.encode(id, forKey: .parameter)
        case .dlna(let udn):
            try container.encode("dlna", forKey: .kind)
            try container.encode(udn, forKey: .parameter)
        case .local:
            try container.encode("local", forKey: .kind)
        case .external(let id):
            try container.encode("external", forKey: .kind)
            try container.encode(id, forKey: .parameter)
        }
    }
}
