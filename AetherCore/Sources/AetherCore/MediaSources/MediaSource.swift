import Foundation

/// The shared contract every media source (mock, Plex, Synology) implements.
///
/// Implementations are typically actors — they own auth state and network plumbing.
public protocol MediaSource: Sendable {
    var id: MediaSourceID { get }
    var displayName: String { get }

    /// All top-level libraries this source exposes.
    func libraries() async throws -> [Library]

    /// Items in a given library. The default sort is `.default` and the
    /// source is free to ignore pagination — `HomeView`'s rails call this
    /// shape for "first N" previews.
    func items(in library: Library.ID) async throws -> [MediaItem]

    /// Items in a library with explicit sort + pagination. The library detail
    /// view passes the user's chosen sort and asks for chunks of `limit`
    /// items at a time, walking `offset` forward as the user scrolls. A
    /// source that can't honour the parameters falls back to a default-order
    /// full fetch via the protocol extension below.
    func items(
        in library: Library.ID,
        sortedBy sort: LibrarySort,
        limit: Int?,
        offset: Int?
    ) async throws -> [MediaItem]

    /// Children of a container item — a show's seasons, a season's episodes.
    /// Returns `[]` for leaf items (movies, episodes) and for sources that
    /// don't model a hierarchy.
    func children(of id: MediaID) async throws -> [MediaItem]

    /// Fresh metadata for one item, when the source can cheaply resolve it.
    /// Player entry points use this to hydrate details that list endpoints may
    /// omit, like Plex audio streams.
    func item(for id: MediaID) async throws -> MediaItem?

    /// Resolve a **fresh, ready-to-play** URL for a playback request.
    ///
    /// Implementations MUST build a new URL on every call — a new transcode
    /// session, the currently-reachable connection + token, and the requested
    /// audio / subtitle streams + start offset. They must never hand back or
    /// string-mutate a previously issued URL. Reusing a stale Plex transcode
    /// session is exactly what surfaces as `NSURLErrorDomain -1008` on audio
    /// switch and on resume-after-a-delay. For server transcodes the
    /// implementation should also **warm up** the stream (confirm the HLS
    /// playlist is actually readable) before returning, so AVPlayer never opens
    /// a not-yet-ready URL. See `PlaybackRequest`.
    func resolvePlayback(_ request: PlaybackRequest) async throws -> ResolvedPlayback

    /// Tear down a server-side transcode session previously handed back in
    /// `ResolvedPlayback.transcodeSessionID`. Called when switching tracks (the
    /// old session, after the new one is live) and on stop. Default: no-op for
    /// sources without server sessions.
    func stopTranscode(sessionID: String) async
}

public extension MediaSource {
    /// Default: no detail endpoint. Callers should fall back to the item they
    /// already have.
    func item(for id: MediaID) async throws -> MediaItem? { nil }

    /// Default: sources without a server transcoder (mock, Synology direct
    /// play) just play the stable direct-play URL; the player seeks
    /// client-side. Plex overrides this to mint a fresh transcode session.
    func resolvePlayback(_ request: PlaybackRequest) async throws -> ResolvedPlayback {
        guard let url = request.directPlayURL else {
            throw PlaybackResolveError.noPlayableStream
        }
        return ResolvedPlayback(url: url, isServerTranscode: false, baseOffsetSeconds: 0)
    }

    /// Default: nothing to tear down.
    func stopTranscode(sessionID: String) async {}

    /// Default: no hierarchy. Plex overrides this to expose seasons + episodes.
    func children(of id: MediaID) async throws -> [MediaItem] { [] }

    /// Default for sort + pagination: ignore both, return the source's native
    /// order. Real connectors override this; `MockMediaSource` and any future
    /// flat source can stay on the default.
    func items(
        in library: Library.ID,
        sortedBy sort: LibrarySort,
        limit: Int?,
        offset: Int?
    ) async throws -> [MediaItem] {
        try await items(in: library)
    }
}

public struct Library: Identifiable, Hashable, Sendable {
    public let id: ID
    public let title: String
    public let kind: MediaItem.Kind

    public init(id: ID, title: String, kind: MediaItem.Kind) {
        self.id = id
        self.title = title
        self.kind = kind
    }

    public struct ID: Hashable, Sendable {
        public let source: MediaSourceID
        public let rawValue: String

        public init(source: MediaSourceID, rawValue: String) {
            self.source = source
            self.rawValue = rawValue
        }
    }
}

// MARK: - Playback resolution

/// How a title is delivered: a stable file the client seeks itself, or a
/// server-side transcode whose HLS timeline starts at a baked-in offset.
public enum PlaybackMode: Sendable, Equatable {
    case directPlay
    case transcode
}

/// A request for a fresh playback URL. Built from a `MediaItem` plus the user's
/// current choices, then resolved by the *source* layer — the player never
/// constructs or mutates Plex URLs itself. Carrying the choices (rather than a
/// pre-built URL) is what lets the resolver mint a brand-new transcode session
/// each time, which is the fix for stale-session `-1008` failures.
public struct PlaybackRequest: Sendable, Equatable {
    public let itemID: MediaID
    public let mode: PlaybackMode
    /// The stable direct-play file URL, when `mode == .directPlay`. Transcode
    /// requests ignore it — the source rebuilds the HLS URL from `itemID`.
    public let directPlayURL: URL?
    public let audioStreamID: String?
    /// `"0"` turns subtitles off (Plex); `nil` leaves the server default.
    public let subtitleStreamID: String?
    public let startTime: Duration?

    public init(
        itemID: MediaID,
        mode: PlaybackMode,
        directPlayURL: URL? = nil,
        audioStreamID: String? = nil,
        subtitleStreamID: String? = nil,
        startTime: Duration? = nil
    ) {
        self.itemID = itemID
        self.mode = mode
        self.directPlayURL = directPlayURL
        self.audioStreamID = audioStreamID
        self.subtitleStreamID = subtitleStreamID
        self.startTime = startTime
    }

    /// Build a request from an item and a start position, reading the item's
    /// current audio / subtitle selection. Mode is derived from the item's
    /// stream kind so the player doesn't have to know about transcoding.
    public init(item: MediaItem, startTime: Duration?) {
        let transcode = item.isServerTranscode
        self.init(
            itemID: item.id,
            mode: transcode ? .transcode : .directPlay,
            directPlayURL: transcode ? nil : item.streamURL,
            audioStreamID: item.selectedAudioTrackID,
            subtitleStreamID: item.selectedSubtitleTrackID,
            startTime: startTime
        )
    }
}

/// The result of resolving a `PlaybackRequest`: a ready-to-play URL plus the
/// timeline facts the session needs to seek and record resume correctly.
public struct ResolvedPlayback: Sendable, Equatable {
    public let url: URL
    /// `true` when the server emits an HLS timeline that already starts at the
    /// requested offset (Plex transcode). The player must **not** seek in that
    /// case — the offset is baked into the stream. Direct play is `false`: the
    /// player seeks client-side.
    public let isServerTranscode: Bool
    /// Content seconds at the stream's `t = 0` — the baked-in transcode offset,
    /// or `0` for direct play. The session adds this back when recording
    /// resume points so saved positions stay absolute.
    public let baseOffsetSeconds: Double
    /// When non-nil, the player should seek to this absolute content second
    /// after the item is ready. Used for direct play and for **small transcode
    /// offsets** — Plex's first HLS segment may not exist for a tiny offset, so
    /// we start the transcode at zero and seek client-side instead.
    public let clientSeekSeconds: Double?
    /// The server transcode session id backing this URL, so the caller can stop
    /// it later (`stopTranscode(sessionID:)`). `nil` for direct play.
    public let transcodeSessionID: String?

    public init(
        url: URL,
        isServerTranscode: Bool,
        baseOffsetSeconds: Double = 0,
        clientSeekSeconds: Double? = nil,
        transcodeSessionID: String? = nil
    ) {
        self.url = url
        self.isServerTranscode = isServerTranscode
        self.baseOffsetSeconds = baseOffsetSeconds
        self.clientSeekSeconds = clientSeekSeconds
        self.transcodeSessionID = transcodeSessionID
    }
}

public enum PlaybackResolveError: Error, Sendable, Equatable {
    /// The source couldn't produce a playable URL (no Part / no reachable
    /// connection / unsupported item).
    case noPlayableStream
    /// The transcode stream didn't become readable within the warm-up window.
    /// `diagnostics` is a sanitised, token-free summary for the Details view.
    case notReady(diagnostics: String)
}
