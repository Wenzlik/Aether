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

    /// `true` when the source implements `downloadURL(for:quality:)` —
    /// drives Detail's Download button visibility. Local Library plays
    /// files in place (nothing to download); Mock has nothing to fetch;
    /// Plex / Jellyfin return `true`. Synchronous so the UI doesn't have
    /// to await before deciding whether to show the button.
    var supportsDownloads: Bool { get }

    /// Optional download capability — returns a stable URL the
    /// `DownloadManager` can hand to `URLSessionDownloadTask`.
    ///
    /// Returns `nil` for sources that don't support downloads (Local
    /// Library plays files in-place; Mock has nothing to fetch). Plex
    /// and Jellyfin override this to return either the original Part /
    /// item file URL (for `.original` quality, no transcode) or a
    /// progressive-MP4 transcode URL (for bitrate-capped qualities).
    ///
    /// The download itself isn't streamed through this method — the URL
    /// is fed to a long-lived background `URLSession`. So the URL must
    /// stay valid for the lifetime of the download (Plex tokens are good
    /// for hours; the Part URL is stable for years).
    func downloadURL(for item: MediaItem, quality: PlaybackQuality) async throws -> URL?

    /// Mark an item **watched on the server**, so the play state syncs back to
    /// Plex / Jellyfin (and every other client), not just inside Aether. Called
    /// when a title plays to the end. Best-effort + non-throwing: a failed
    /// scrobble must never disrupt playback teardown. Default: no-op for sources
    /// without server-side watch state (Mock, offline).
    func markWatched(_ id: MediaID) async

    /// Mark an item **unwatched on the server** — the inverse of `markWatched`,
    /// for the manual "Mark as Unwatched" action. Best-effort + non-throwing.
    /// Default: no-op.
    func markUnwatched(_ id: MediaID) async

    /// **Source-provided** skip segments (intro / recap / credits / commercial)
    /// for an item — Plex markers, Jellyfin MediaSegments. Drives Skip Intro /
    /// Skip Credits / Auto-Play-Next. Best-effort + non-throwing: returns `[]`
    /// when the source has no segment data, so skip controls stay hidden.
    /// Aether never detects these locally. Default: none.
    func segments(for id: MediaID) async -> [PlaybackSegment]

    /// The next episode after `id` within the same season (Auto-Play-Next), or
    /// `nil`. The default resolves it generically from `item(for:)` + `parentID`
    /// + `children(of:)`, so any source that populates those gets it for free.
    func nextEpisode(after id: MediaID) async -> MediaItem?

    /// Titles **similar** to `id` — Plex's related hub, Jellyfin's `/Similar` —
    /// for the Detail screen's "More Like This" rail. Best-effort + non-throwing:
    /// returns `[]` when the source has no recommendation data, so the rail just
    /// stays hidden. Default: none.
    func related(to id: MediaID) async -> [MediaItem]

    /// Whether the source has a server-synced **favorite** concept. Jellyfin
    /// does (`UserData.IsFavorite`); Plex doesn't (no per-item favorite in the
    /// PMS API), so its favorite star is hidden. Default: `false`.
    var supportsFavorites: Bool { get }

    /// Set the item's **favorite** state on the server, so it syncs across
    /// clients. Best-effort + non-throwing. Default: no-op for sources without
    /// a favorite concept.
    func setFavorite(_ id: MediaID, to favorite: Bool) async

    /// Whether the source exposes server-side **collections** (Plex collections
    /// / Jellyfin BoxSets) for Library browsing (#273). Default: `false`.
    var supportsCollections: Bool { get }

    /// Every collection across the source's libraries. Best-effort +
    /// non-throwing — `[]` just hides the facet. Default: none.
    func collections() async -> [MediaCollection]

    /// The titles inside one collection. Best-effort. Default: none.
    func items(inCollection id: MediaID) async -> [MediaItem]

    /// Whether the source can list **people** (actors / directors) for Library
    /// browsing (#273). Default: `false`.
    var supportsPeople: Bool { get }

    /// Every person of `kind` across the source's libraries. Best-effort.
    /// Default: none.
    func people(_ kind: PersonKind) async -> [MediaPerson]

    /// The titles featuring `person`. Takes the whole person (not just an id)
    /// because Plex picks its filter parameter from the person's `kind`.
    /// Best-effort. Default: none.
    func items(withPerson person: MediaPerson) async -> [MediaItem]
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

    /// Default: no download capability. Plex / Jellyfin override.
    var supportsDownloads: Bool { false }

    /// Default: no download capability. Plex / Jellyfin override.
    func downloadURL(for item: MediaItem, quality: PlaybackQuality) async throws -> URL? { nil }

    /// Default: no server-side watch state to update. Plex / Jellyfin override.
    func markWatched(_ id: MediaID) async {}

    /// Default: no server-side watch state to update. Plex / Jellyfin override.
    func markUnwatched(_ id: MediaID) async {}

    /// Default: no segment data. Plex / Jellyfin override.
    func segments(for id: MediaID) async -> [PlaybackSegment] { [] }

    /// Default: no recommendation data. Plex / Jellyfin override.
    func related(to id: MediaID) async -> [MediaItem] { [] }

    /// Default: no favorite concept. Jellyfin overrides.
    var supportsFavorites: Bool { false }

    /// Default: no server-side favorite to update. Jellyfin overrides.
    func setFavorite(_ id: MediaID, to favorite: Bool) async {}

    /// Default: no collections. Plex / Jellyfin override.
    var supportsCollections: Bool { false }

    /// Default: no collections. Plex / Jellyfin override.
    func collections() async -> [MediaCollection] { [] }

    /// Default: no collections. Plex / Jellyfin override.
    func items(inCollection id: MediaID) async -> [MediaItem] { [] }

    /// Default: no people directory. Plex / Jellyfin override.
    var supportsPeople: Bool { false }

    /// Default: no people directory. Plex / Jellyfin override.
    func people(_ kind: PersonKind) async -> [MediaPerson] { [] }

    /// Default: no people directory. Plex / Jellyfin override.
    func items(withPerson person: MediaPerson) async -> [MediaItem] { [] }

    /// Generic next-episode resolver: hydrate the item, fetch its season's
    /// episodes, return the one after it. Works for any source that fills in
    /// `parentID` and implements `children(of:)`. Same-season only (v1);
    /// returns `nil` at a season boundary.
    func nextEpisode(after id: MediaID) async -> MediaItem? {
        guard let current = try? await item(for: id),
              current.kind == .episode,
              let parent = current.parentID else { return nil }
        let siblings = (try? await children(of: parent)) ?? []
        guard let index = siblings.firstIndex(where: { $0.id == id }),
              index + 1 < siblings.count else { return nil }
        return siblings[index + 1]
    }

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

/// What the server actually agreed to do for a playback request, mirroring
/// Plex's `/video/:/transcode/universal/decision` verdict (`directplay` /
/// `directstream` / `transcode`).
///
/// - `directPlay` — the client opens the original file as-is; no server work.
/// - `directStream` — the server remuxes container only (cheap, lossless).
/// - `transcode` — the server re-encodes video and/or audio (CPU-intensive).
///
/// Priority is always Direct Play → Direct Stream → Transcode. The user's
/// `PlaybackQuality` choice biases this: `original` asks for direct play and
/// only falls back if the client can't handle the codec/container; a bitrate
/// cap forces a transcode.
public enum PlaybackDecisionMode: String, Sendable, Equatable {
    case directPlay
    case directStream
    case transcode

    /// Short label for the Detail-screen "Playback:" line.
    public var displayName: String {
        switch self {
        case .directPlay:   return "Direct Play"
        case .directStream: return "Direct Stream"
        case .transcode:    return "Transcode"
        }
    }
}

/// User-selectable quality on the movie detail screen.
///
/// `original` mirrors Plex Web's default — try Direct Play, fall back to Direct
/// Stream, and only transcode when truly necessary. The bitrate caps force a
/// transcode at that ceiling (for slow networks or thumbnail-quality previews).
public enum PlaybackQuality: String, Sendable, Hashable, CaseIterable, Codable {
    case original
    case convertAutomatically
    case bitrate20Mbps1080p
    case bitrate12Mbps1080p
    case bitrate8Mbps1080p
    case bitrate4Mbps720p
    case bitrate2Mbps720p
    case bitrate720kbps

    public var displayName: String {
        switch self {
        case .original:             return "Original"
        case .convertAutomatically: return "Convert Automatically"
        case .bitrate20Mbps1080p:   return "20 Mbps 1080p"
        case .bitrate12Mbps1080p:   return "12 Mbps 1080p"
        case .bitrate8Mbps1080p:    return "8 Mbps 1080p"
        case .bitrate4Mbps720p:     return "4 Mbps 720p"
        case .bitrate2Mbps720p:     return "2 Mbps 720p"
        case .bitrate720kbps:       return "720 kbps"
        }
    }

    /// Max video bitrate the server should respect, in **kilobits per second**.
    /// `nil` means no cap — used by `original` and `convertAutomatically`.
    public var maxVideoBitrateKbps: Int? {
        switch self {
        case .original, .convertAutomatically: return nil
        case .bitrate20Mbps1080p: return 20_000
        case .bitrate12Mbps1080p: return 12_000
        case .bitrate8Mbps1080p:  return 8_000
        case .bitrate4Mbps720p:   return 4_000
        case .bitrate2Mbps720p:   return 2_000
        case .bitrate720kbps:     return 720
        }
    }

    /// Max video resolution as a `WxH` string Plex understands on the decision
    /// endpoint. `nil` means no cap.
    public var videoResolution: String? {
        switch self {
        case .bitrate20Mbps1080p, .bitrate12Mbps1080p, .bitrate8Mbps1080p:
            return "1920x1080"
        case .bitrate4Mbps720p, .bitrate2Mbps720p, .bitrate720kbps:
            return "1280x720"
        case .original, .convertAutomatically:
            return nil
        }
    }

    /// Whether the request should ask Plex to attempt Direct Play. Only
    /// `original` does — every other choice has a transcode goal in mind.
    public var allowsDirectPlay: Bool {
        self == .original
    }
}

/// Pre-playback media information shown on the Detail screen: codecs, file
/// resolution, source bitrate, HDR/Dolby Vision badges. Populated from Plex
/// metadata, used purely for display.
public struct MediaInfo: Sendable, Hashable, Codable {
    public let videoCodec: String?
    public let audioCodec: String?
    public let audioChannels: Int?
    /// Display string like `"1080p"`, `"4K"`. We keep the server's text so we
    /// don't have to translate every Plex resolution alias here.
    public let videoResolution: String?
    /// Source bitrate in **kilobits per second**.
    public let bitrateKbps: Int?
    public let isHDR: Bool
    public let isDolbyVision: Bool
    /// Source file container, e.g. `"mp4"`, `"mkv"`. Used as a heuristic for
    /// the projected playback mode on Detail (mp4/mov/m4v → Direct Play).
    public let container: String?
    /// Total size of the source file in **bytes** (Plex `Part.size`, Jellyfin
    /// `MediaSourceInfo.Size`). Rendered human-readable ("12.4 GB") in the
    /// Technical Details section. `nil` when the source didn't report it.
    public let fileSizeBytes: Int64?

    public init(
        videoCodec: String? = nil,
        audioCodec: String? = nil,
        audioChannels: Int? = nil,
        videoResolution: String? = nil,
        bitrateKbps: Int? = nil,
        isHDR: Bool = false,
        isDolbyVision: Bool = false,
        container: String? = nil,
        fileSizeBytes: Int64? = nil
    ) {
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.audioChannels = audioChannels
        self.videoResolution = videoResolution
        self.bitrateKbps = bitrateKbps
        self.isHDR = isHDR
        self.isDolbyVision = isDolbyVision
        self.container = container
        self.fileSizeBytes = fileSizeBytes
    }
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
    /// Plex Part id (e.g. `"17905"`). Drives the `PUT /library/parts/{partId}`
    /// stream-selection step that mirrors Plex Web. `nil` for sources without a
    /// Part concept (mock / Synology direct play).
    public let partID: String?
    public let audioStreamID: String?
    /// `"0"` turns subtitles off (Plex); `nil` leaves the server default.
    public let subtitleStreamID: String?
    /// The Detail-screen quality choice — drives `maxVideoBitrate` /
    /// `videoResolution` and the `directPlay` flag on the decision call.
    public let quality: PlaybackQuality
    public let startTime: Duration?
    /// `true` when the user's audio / subtitle pick differs from the source's
    /// own default — the signal for sources that must abandon direct play and
    /// transcode to honor a selection (#68: Jellyfin's `static=true` stream
    /// ignores `AudioStreamIndex` entirely).
    public let hasExplicitTrackSelection: Bool

    public init(
        itemID: MediaID,
        mode: PlaybackMode,
        directPlayURL: URL? = nil,
        partID: String? = nil,
        audioStreamID: String? = nil,
        subtitleStreamID: String? = nil,
        quality: PlaybackQuality = .original,
        startTime: Duration? = nil,
        hasExplicitTrackSelection: Bool = false
    ) {
        self.itemID = itemID
        self.mode = mode
        self.directPlayURL = directPlayURL
        self.partID = partID
        self.audioStreamID = audioStreamID
        self.subtitleStreamID = subtitleStreamID
        self.quality = quality
        self.startTime = startTime
        self.hasExplicitTrackSelection = hasExplicitTrackSelection
    }

    /// Build a request from an item and a start position, reading the item's
    /// current audio / subtitle / quality selection. Mode is derived from the
    /// item's stream kind — but the Plex source ignores it once `partID` is
    /// present, because the decision endpoint is the real source of truth.
    ///
    /// The subtitle bridge: `MediaItem.selectedSubtitleTrackID == nil` is the
    /// user's explicit "Off" choice (the row with no id in the picker). On the
    /// wire Plex wants `"0"` for that, while `nil` means "don't touch the
    /// current selection." So we map nil → `"0"` whenever the item *has*
    /// subtitle tracks to choose from, and leave it nil when there are none.
    public init(item: MediaItem, startTime: Duration?) {
        let transcode = item.isServerTranscode
        let subtitleID: String? = {
            if !item.subtitleTracks.isEmpty {
                return item.selectedSubtitleTrackID ?? "0"
            }
            return item.selectedSubtitleTrackID
        }()
        self.init(
            itemID: item.id,
            mode: transcode ? .transcode : .directPlay,
            directPlayURL: transcode ? nil : item.streamURL,
            partID: item.partID,
            audioStreamID: item.selectedAudioTrackID,
            subtitleStreamID: subtitleID,
            quality: item.selectedQuality,
            startTime: startTime,
            hasExplicitTrackSelection: item.explicitTrackSelection ?? false
        )
    }
}

/// The result of resolving a `PlaybackRequest`: a ready-to-play URL plus the
/// timeline facts the session needs to seek and record resume correctly.
public struct ResolvedPlayback: Sendable, Equatable {
    public let url: URL
    /// `true` when the server emits an HLS timeline that already starts at the
    /// requested offset (Plex transcode / direct stream). The player must
    /// **not** seek in that case — the offset is baked into the stream. Direct
    /// play is `false`: the player seeks client-side.
    public let isServerTranscode: Bool
    /// The transcode start offset baked into the URL (or `0`). **Informational
    /// only** — `PlaybackSession` does NOT add this to `currentTime()`. In
    /// practice `AVPlayer.currentTime()` is the absolute content time on every
    /// path here (direct play, client-seek, and server-baked offset alike), so
    /// adding it back double-counted and made resume points run away. Do not
    /// re-introduce an add-back without verifying the transcoder's timeline on
    /// device (see the note in `PlaybackSession.prepare`).
    public let baseOffsetSeconds: Double
    /// When non-nil, the player should seek to this absolute content second
    /// after the item is ready. Used for direct play and for **small transcode
    /// offsets** — Plex's first HLS segment may not exist for a tiny offset, so
    /// we start the transcode at zero and seek client-side instead.
    public let clientSeekSeconds: Double?
    /// The server transcode session id backing this URL, so the caller can stop
    /// it later (`stopTranscode(sessionID:)`). `nil` for direct play.
    public let transcodeSessionID: String?
    /// What the server actually agreed to do, when the source asked. `nil` for
    /// sources without a decision step (Synology / Mock / legacy paths) — in
    /// that case the caller infers it from `isServerTranscode`.
    public let decision: PlaybackDecisionMode?

    public init(
        url: URL,
        isServerTranscode: Bool,
        baseOffsetSeconds: Double = 0,
        clientSeekSeconds: Double? = nil,
        transcodeSessionID: String? = nil,
        decision: PlaybackDecisionMode? = nil
    ) {
        self.url = url
        self.isServerTranscode = isServerTranscode
        self.baseOffsetSeconds = baseOffsetSeconds
        self.clientSeekSeconds = clientSeekSeconds
        self.transcodeSessionID = transcodeSessionID
        self.decision = decision
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
