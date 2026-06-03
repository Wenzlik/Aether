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

    /// User's quality choice at queue time. Stored so we can re-issue the
    /// download with the same parameters after a Retry, and so the
    /// Storage section can later report "Inception · 8 Mbps · 1.4 GB".
    public let quality: PlaybackQuality

    /// `Date` the job was first recorded. Used for stable sort order in
    /// the Library "Downloaded" rail (newest first).
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        mediaID: MediaID,
        title: String,
        posterURL: URL? = nil,
        quality: PlaybackQuality,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.mediaID = mediaID
        self.title = title
        self.posterURL = posterURL
        self.quality = quality
        self.createdAt = createdAt
    }
}

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
        case "synology":
            guard let parameter else {
                throw DecodingError.dataCorruptedError(
                    forKey: .parameter, in: container,
                    debugDescription: "synology source missing host"
                )
            }
            self = .synology(host: parameter)
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
        case .synology(let host):
            try container.encode("synology", forKey: .kind)
            try container.encode(host, forKey: .parameter)
        }
    }
}
