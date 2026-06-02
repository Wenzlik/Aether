import Foundation
import os

/// A Plex Media Server connection wired up as an Aether `MediaSource`.
///
/// Holds the configuration, the auth token, the **ranked list of connections**,
/// and an `APIClient`. Resolves which connection actually works at runtime by
/// probing `/identity` in rank order — so the same source object plays on the
/// LAN at home and over a remote / relay connection away from home, without
/// re-running discovery.
///
/// Implements:
/// - `libraries()` → `GET /library/sections`
/// - `items(in:)`  → `GET /library/sections/{key}/all`
public actor PlexMediaSource: MediaSource {
    public let id: MediaSourceID
    public let displayName: String

    private let api: any APIClient
    private let configuration: PlexConfiguration
    private let accessToken: String
    private let connections: [PlexServerRecord.Connection]
    private let decoder: JSONDecoder

    /// How long a single connection probe is allowed to take before we move on
    /// to the next candidate. Kept short so leaving the LAN fails over quickly
    /// instead of hanging on the default 60s URLSession timeout.
    private let probeTimeout: TimeInterval

    /// The connection we've confirmed reachable this session. Lazily resolved
    /// on the first request and reused afterwards.
    private var resolvedBaseURL: URL?

    /// Whether the resolved connection is on the LAN — drives `location=lan` on
    /// transcode requests (Plex tunes its decisions by client location).
    private var resolvedIsLocal = false

    /// Owns transcode session ids, playlist warm-up, and session teardown.
    private lazy var sessionManager = PlexTranscodeSessionManager(api: api)

    /// Offsets at or below this (seconds) are NOT sent to the transcoder — the
    /// first HLS segment for a tiny offset may not exist yet, yielding -1008.
    /// We start the transcode at zero and seek the player instead.
    private static let smallOffsetThreshold: Double = 12

    /// Warm-up backoff before AVPlayer gets the URL. Overridable so tests don't
    /// wait the real ~3.75 s.
    private let warmUpBackoff: [Duration]

    private static let log = Logger(subsystem: "cz.zmrhal.aether", category: "plex.transcode")

    public init(
        serverID: String,
        displayName: String,
        accessToken: String,
        connections: [PlexServerRecord.Connection],
        configuration: PlexConfiguration,
        api: any APIClient,
        probeTimeout: TimeInterval = 4,
        warmUpBackoff: [Duration] = PlexTranscodeSessionManager.defaultBackoff
    ) {
        self.id = .plex(serverID: serverID)
        self.displayName = displayName
        self.accessToken = accessToken
        self.connections = connections
        self.configuration = configuration
        self.api = api
        self.probeTimeout = probeTimeout
        self.warmUpBackoff = warmUpBackoff
        self.decoder = JSONDecoder()
    }

    // MARK: - MediaSource

    public func libraries() async throws -> [Library] {
        let base = try await resolveBaseURL()
        let request = request(base: base, path: "/library/sections")
        let response = try await api.decode(
            PlexAPI.LibrarySectionsResponse.self,
            from: request,
            decoder: decoder
        )
        let directories = response.mediaContainer.directory ?? []

        return directories.compactMap { dto in
            guard let kind = dto.kind else { return nil }  // skip music, photos for 0.2
            return Library(
                id: .init(source: id, rawValue: dto.key),
                title: dto.title,
                kind: kind
            )
        }
    }

    public func items(in libraryID: Library.ID) async throws -> [MediaItem] {
        try await items(in: libraryID, sortedBy: .default, limit: nil, offset: nil)
    }

    /// Sorted + paginated variant. Plex's `/library/sections/{key}/all` accepts:
    /// - `sort=<field>:<direction>` (see `LibrarySort.plexParameter`)
    /// - `X-Plex-Container-Start=<offset>`  (zero-based)
    /// - `X-Plex-Container-Size=<limit>`
    ///
    /// All three are query items here; Plex also accepts the `X-Plex-Container-*`
    /// values as HTTP headers, but using query items keeps the request shape
    /// uniform and easy to inspect in tests.
    public func items(
        in libraryID: Library.ID,
        sortedBy sort: LibrarySort,
        limit: Int?,
        offset: Int?
    ) async throws -> [MediaItem] {
        let base = try await resolveBaseURL()
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "sort", value: sort.plexParameter)
        ]
        if let offset {
            queryItems.append(URLQueryItem(name: "X-Plex-Container-Start", value: String(offset)))
        }
        if let limit {
            queryItems.append(URLQueryItem(name: "X-Plex-Container-Size", value: String(limit)))
        }
        let request = request(
            base: base,
            path: "/library/sections/\(libraryID.rawValue)/all",
            queryItems: queryItems
        )
        let response = try await api.decode(
            PlexAPI.LibraryItemsResponse.self,
            from: request,
            decoder: decoder
        )
        let metadata = response.mediaContainer.metadata ?? []
        return metadata.map { mapMetadataToMediaItem($0, base: base) }
    }

    /// Children of a container: a show's seasons, or a season's episodes.
    /// `GET /library/metadata/{ratingKey}/children` returns the same
    /// `MediaContainer.Metadata` shape as a library listing.
    public func children(of id: MediaID) async throws -> [MediaItem] {
        let base = try await resolveBaseURL()
        let request = request(base: base, path: "/library/metadata/\(id.rawValue)/children")
        let response = try await api.decode(
            PlexAPI.LibraryItemsResponse.self,
            from: request,
            decoder: decoder
        )
        let metadata = response.mediaContainer.metadata ?? []
        return metadata.map { mapMetadataToMediaItem($0, base: base) }
    }

    /// Fetch a single item's full metadata. Plex library rails often omit
    /// `Media.Part.Stream`, which means the player cannot know about alternate
    /// audio tracks. `/library/metadata/{ratingKey}` includes the richer shape,
    /// so hydrate immediately before playback.
    public func item(for id: MediaID) async throws -> MediaItem? {
        guard id.source == self.id else { return nil }
        let base = try await resolveBaseURL()
        let request = request(base: base, path: "/library/metadata/\(id.rawValue)")
        let response = try await api.decode(
            PlexAPI.LibraryItemsResponse.self,
            from: request,
            decoder: decoder
        )
        return response.mediaContainer.metadata?.first.map { mapMetadataToMediaItem($0, base: base) }
    }

    /// Build a fresh playback URL for the request.
    ///
    /// This is the single place Plex playback URLs are constructed for the
    /// player — `PlaybackSession` hands us a `PlaybackRequest` and gets back a
    /// brand-new URL every time (new transcode session, current connection +
    /// token, requested audio / subtitle streams, baked-in offset). Nothing
    /// reuses or string-mutates a prior URL, so a reaped transcode session
    /// can't resurface as `-1008` on audio switch / resume.
    public func resolvePlayback(_ request: PlaybackRequest) async throws -> ResolvedPlayback {
        switch request.mode {
        case .directPlay:
            // Direct-play files are stable (path + token, no session); the
            // player seeks client-side, so there's nothing to rebuild.
            guard let url = request.directPlayURL else {
                throw PlaybackResolveError.noPlayableStream
            }
            return ResolvedPlayback(url: url, isServerTranscode: false, baseOffsetSeconds: 0)

        case .transcode:
            let base = try await resolveBaseURL()
            let isLocal = resolvedIsLocal
            let rawOffset = request.startTime.map(Self.seconds(_:)).map { max(0, $0) } ?? 0
            // Small offsets aren't sent to Plex (missing first segment); we seek
            // the player after warm-up instead. Larger offsets are baked in.
            let bakeOffset = rawOffset > Self.smallOffsetThreshold
            let sessionID = await sessionManager.newSessionID()

            guard let url = transcodeURL(
                base: base,
                ratingKey: request.itemID.rawValue,
                audioStreamID: request.audioStreamID,
                subtitleStreamID: request.subtitleStreamID,
                offsetSeconds: bakeOffset ? rawOffset : nil,
                sessionID: sessionID,
                location: isLocal ? "lan" : nil
            ) else {
                throw PlaybackResolveError.noPlayableStream
            }

            // Warm up: don't hand AVPlayer a cold URL. Poll the playlist until
            // it's readable, then mark the session active.
            let outcome = await sessionManager.warmUp(warmUpRequest(for: url), delays: warmUpBackoff)
            guard outcome.ready else {
                // Log the EXACT request (token redacted) + Plex's error body, and
                // probe which parameter combination Plex rejects — evidence, not
                // guesses. (Only runs on the failure path.)
                Self.log.error("transcode warm-up FAILED status=\(outcome.lastStatus.map(String.init) ?? "none", privacy: .public) extm3u=\(outcome.sawPlaylistMarker, privacy: .public) body=\(outcome.bodySnippet ?? "-", privacy: .public)")
                Self.log.error("transcode params: \(Self.redactedParams(url), privacy: .public)")
                let probe = await isolationProbe(
                    base: base, ratingKey: request.itemID.rawValue,
                    offsetSeconds: bakeOffset ? rawOffset : nil,
                    audioStreamID: request.audioStreamID, subtitleStreamID: request.subtitleStreamID,
                    isLocal: isLocal
                )
                Self.log.error("transcode isolation probe → \(probe, privacy: .public)")
                throw PlaybackResolveError.notReady(diagnostics: Self.diagnostics(
                    isLocal: isLocal, base: base, sessionID: sessionID, offset: rawOffset,
                    audioStreamID: request.audioStreamID, subtitleStreamID: request.subtitleStreamID,
                    outcome: outcome
                ) + " · body=\(outcome.bodySnippet ?? "-") · probe[\(probe)]")
            }
            await sessionManager.markActive(sessionID)

            return ResolvedPlayback(
                url: url,
                isServerTranscode: true,
                baseOffsetSeconds: bakeOffset ? rawOffset : 0,
                clientSeekSeconds: (!bakeOffset && rawOffset > 0) ? rawOffset : nil,
                transcodeSessionID: sessionID
            )
        }
    }

    /// Stop a transcode session on the server (`/transcode/universal/stop`).
    public func stopTranscode(sessionID: String) async {
        guard let base = resolvedBaseURL, let url = stopURL(base: base, sessionID: sessionID) else { return }
        var request = URLRequest(url: url)
        for (key, value) in configuration.commonHeaders { request.setValue(value, forHTTPHeaderField: key) }
        await sessionManager.stop(request, sessionID: sessionID)
    }

    /// A warm-up GET for an `.m3u8` URL. The token already rides in the query
    /// (AVPlayer can't set headers), so this just adds the common headers.
    private func warmUpRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        for (key, value) in configuration.commonHeaders { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }

    private nonisolated func stopURL(base: URL, sessionID: String) -> URL? {
        var components = URLComponents(
            url: base.appendingPathComponent("/video/:/transcode/universal/stop"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "session", value: sessionID),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: configuration.clientIdentifier),
            URLQueryItem(name: "X-Plex-Token", value: accessToken)
        ]
        return components?.url
    }

    /// Token-free, URL-free diagnostic summary for the player's Details view.
    nonisolated static func diagnostics(
        isLocal: Bool,
        base: URL,
        sessionID: String,
        offset: Double,
        audioStreamID: String?,
        subtitleStreamID: String?,
        outcome: PlexTranscodeSessionManager.WarmUpOutcome
    ) -> String {
        "connection=\(isLocal ? "lan" : "remote") · host=\(base.host ?? "?") · "
            + "session=\(sessionID.prefix(8)) · offset=\(Int(offset))s · "
            + "audio=\(audioStreamID ?? "-") · subtitle=\(subtitleStreamID ?? "-") · "
            + "warm-up: \(outcome.attempts) attempts, status=\(outcome.lastStatus.map(String.init) ?? "none"), EXTM3U=\(outcome.sawPlaylistMarker)"
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    /// Every query parameter name=value of a transcode URL, with the token
    /// redacted — so we can compare exactly what we send vs. Plex Web / kodi.
    nonisolated static func redactedParams(_ url: URL) -> String {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return "-" }
        return items.map { item in
            let value = item.name == "X-Plex-Token" ? "<redacted>" : (item.value ?? "")
            return "\(item.name)=\(value)"
        }.joined(separator: "&")
    }

    /// Find the smallest parameter combination Plex rejects: probe `offset`,
    /// `offset+audio`, `offset+subtitle`, `offset+audio+subtitle` with one GET
    /// each (fresh session per probe) and report the HTTP status of each. Runs
    /// only when the real warm-up already failed.
    private func isolationProbe(
        base: URL,
        ratingKey: String,
        offsetSeconds: Double?,
        audioStreamID: String?,
        subtitleStreamID: String?,
        isLocal: Bool
    ) async -> String {
        func status(audio: String?, subtitle: String?) async -> String {
            let sessionID = await sessionManager.newSessionID()
            guard let url = transcodeURL(
                base: base, ratingKey: ratingKey,
                audioStreamID: audio, subtitleStreamID: subtitle,
                offsetSeconds: offsetSeconds, sessionID: sessionID,
                location: isLocal ? "lan" : nil
            ) else { return "?" }
            return await sessionManager.probeStatus(warmUpRequest(for: url)).map(String.init) ?? "err"
        }
        let offsetOnly = await status(audio: nil, subtitle: nil)
        let withAudio = await status(audio: audioStreamID, subtitle: nil)
        let withSubtitle = await status(audio: nil, subtitle: subtitleStreamID)
        let withBoth = await status(audio: audioStreamID, subtitle: subtitleStreamID)
        return "offset=\(offsetOnly) offset+audio=\(withAudio) offset+subtitle=\(withSubtitle) offset+audio+subtitle=\(withBoth)"
    }

    // MARK: - Connection resolution + failover

    /// Return a reachable connection's base URL, probing `/identity` in ranked
    /// order. The first success is cached for the rest of the session.
    /// Throws `PlexConnectionError.noReachableConnection` when every candidate
    /// fails (e.g. server offline, or off-network with no remote connection).
    func resolveBaseURL() async throws -> URL {
        if let resolvedBaseURL { return resolvedBaseURL }

        for connection in connections {
            guard let base = connection.url else { continue }
            if await isReachable(base) {
                resolvedBaseURL = base
                resolvedIsLocal = connection.isLocal
                return base
            }
        }
        throw PlexConnectionError.noReachableConnection
    }

    /// Forget the cached connection — call when a request later fails so the
    /// next request re-probes (e.g. the user moved from LAN to cellular while
    /// the app was backgrounded).
    public func invalidateConnection() {
        resolvedBaseURL = nil
        resolvedIsLocal = false
    }

    private func isReachable(_ base: URL) async -> Bool {
        var request = request(base: base, path: "/identity")
        request.timeoutInterval = probeTimeout
        do {
            let (_, response) = try await api.data(for: request)
            return (200..<300).contains(response.statusCode)
        } catch {
            return false
        }
    }

    // MARK: - Mapping

    /// Translate one Plex `Metadata` into Aether's source-agnostic `MediaItem`.
    ///
    /// - Plex runtimes are in **milliseconds**; we convert to seconds.
    /// - Poster / backdrop / stream URLs are built against the resolved base
    ///   URL and tokenised via a query parameter so plain `AsyncImage` /
    ///   `AVPlayer` work without setting headers.
    /// - `streamURL` resolution (see `streamURL(for:base:)`):
    ///   - containers (shows, seasons) → `nil` (not directly playable),
    ///   - AVPlayer-friendly container (mp4/m4v/mov) → the direct-play file URL,
    ///   - anything else (mkv, avi, ts, …) → the server transcode HLS URL.
    nonisolated func mapMetadataToMediaItem(_ dto: PlexAPI.Metadata, base: URL) -> MediaItem {
        let streamURL = streamURL(for: dto, base: base)
        // Track switching is a transcode-only capability: the server honours
        // audioStreamID / subtitleStreamID on a `start.m3u8` session. Direct
        // play has no such knob, so we don't surface tracks the user can't act
        // on (AVKit's native picker covers direct-play subtitles in the player).
        let isTranscode = streamURL?.path == "/video/:/transcode/universal/start.m3u8"
        let audioTracks = isTranscode ? dto.audioTracks : []
        let subtitleTracks = isTranscode ? dto.subtitleTracks : []
        return MediaItem(
            id: .init(source: id, rawValue: dto.ratingKey),
            title: dto.title,
            kind: dto.kind,
            year: dto.year,
            runtime: dto.duration.map { .seconds(Double($0) / 1000.0) },
            summary: dto.summary,
            posterURL: tokenisedURL(base: base, path: dto.thumb),
            backdropURL: tokenisedURL(base: base, path: dto.art),
            streamURL: streamURL,
            audioTracks: audioTracks,
            selectedAudioTrackID: audioTracks.first(where: \.isSelected)?.id,
            subtitleTracks: subtitleTracks,
            selectedSubtitleTrackID: subtitleTracks.first(where: \.isSelected)?.id
        )
    }

    // MARK: - Stream URL resolution (direct play vs transcode)

    /// Containers AVPlayer opens natively. Anything outside this set goes
    /// through the server transcoder, which always yields playable HLS.
    private static let directPlayContainers: Set<String> = ["mp4", "m4v", "mov"]

    /// Decide the stream URL for an item:
    /// - no Part → `nil` (a container like a show / season).
    /// - friendly container → direct-play file URL (pristine, no server load).
    /// - otherwise → transcode HLS URL (the server remuxes or re-encodes;
    ///   `directStream=1` means a common MKV/H.264/AAC just gets remuxed, which
    ///   is fast and lossless).
    nonisolated func streamURL(for dto: PlexAPI.Metadata, base: URL) -> URL? {
        guard dto.firstPartKey != nil else { return nil }

        if let container = dto.firstContainer?.lowercased(),
           Self.directPlayContainers.contains(container) {
            return tokenisedURL(base: base, path: dto.firstPartKey)
        }
        // Unknown or unfriendly container → let the server decide / transcode.
        return transcodeURL(
            base: base,
            ratingKey: dto.ratingKey,
            audioStreamID: dto.selectedAudioTrackID
        )
    }

    /// Build a universal-transcoder HLS URL for an item.
    ///
    /// `directStream=1` lets the server remux when only the container is wrong
    /// (the common, cheap case) and full-transcode only when codecs truly need
    /// it — i.e. "Aether requests; the server decides." The token rides in the
    /// query because `AVPlayer` fetches the playlist directly.
    nonisolated func transcodeURL(
        base: URL,
        ratingKey: String,
        audioStreamID: String? = nil,
        subtitleStreamID: String? = nil,
        offsetSeconds: Double? = nil,
        sessionID: String? = nil,
        location: String? = nil
    ) -> URL? {
        var components = URLComponents(
            url: base.appendingPathComponent("/video/:/transcode/universal/start.m3u8"),
            resolvingAgainstBaseURL: false
        )
        // A brand-new session id every call. Plex keys a running transcode by
        // its session; reusing one that the server has already reaped (after
        // pause/idle) returns segments that 404 → NSURLError -1008. A fresh id
        // forces a new transcode the server can actually serve. `resolvePlayback`
        // passes an explicit id so it can warm up + later stop that session.
        let session = sessionID ?? UUID().uuidString
        var queryItems = [
            URLQueryItem(name: "path", value: "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "protocol", value: "hls"),
            URLQueryItem(name: "directPlay", value: "0"),
            URLQueryItem(name: "directStream", value: "1"),
            URLQueryItem(name: "fastSeek", value: "1"),
            URLQueryItem(name: "mediaIndex", value: "0"),
            URLQueryItem(name: "partIndex", value: "0"),
            URLQueryItem(name: "maxVideoBitrate", value: "20000"),
            URLQueryItem(name: "videoQuality", value: "100"),
            URLQueryItem(name: "session", value: session),
            URLQueryItem(name: "X-Plex-Session-Identifier", value: session),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: configuration.clientIdentifier),
            URLQueryItem(name: "X-Plex-Product", value: configuration.product),
            URLQueryItem(name: "X-Plex-Platform", value: configuration.platform),
            URLQueryItem(name: "X-Plex-Token", value: accessToken)
        ]
        if let audioStreamID {
            // Select exactly this audio stream. `directStreamAudio=0` is the
            // key: with `=1` the server keeps *every* source track as an
            // alternate HLS rendition, AVPlayer just plays the default one, and
            // `audioStreamID` is effectively ignored — so picking a track on
            // Detail had no audible effect. `=0` makes the transcoder emit only
            // the chosen track, so the selection is honoured. (Track switching
            // now happens on Detail before playback, not via a transport-bar
            // picker, so we no longer need all renditions present.)
            queryItems.append(URLQueryItem(name: "audioStreamID", value: audioStreamID))
            queryItems.append(URLQueryItem(name: "directStreamAudio", value: "0"))
        } else {
            // No explicit choice: keep all tracks as renditions (the default
            // track plays; nothing to honour).
            queryItems.append(URLQueryItem(name: "directStreamAudio", value: "1"))
        }
        if let subtitleStreamID {
            // `subtitleStreamID=0` disables subtitles (Plex convention).
            queryItems.append(URLQueryItem(name: "subtitleStreamID", value: subtitleStreamID))
        }
        if let offsetSeconds, offsetSeconds > 0 {
            // Start the transcode at the resume point so the server actually
            // produces segments there — seeking a from-zero transcode asks for
            // segments it never made → -1008.
            queryItems.append(URLQueryItem(name: "offset", value: String(Int(offsetSeconds.rounded()))))
        }
        if let location {
            // Tell Plex where we are (e.g. `lan`) so it tunes transcode/direct
            // decisions — matches the official clients' behaviour.
            queryItems.append(URLQueryItem(name: "location", value: location))
        }
        components?.queryItems = queryItems
        return components?.url
    }

    // MARK: - URL helpers

    /// Build a PMS request against a resolved base URL, attaching the server's
    /// common headers + `X-Plex-Token`.
    nonisolated func request(base: URL, path: String, queryItems: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(
            url: base.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        var request = URLRequest(url: components.url!)
        for (key, value) in configuration.commonHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue(accessToken, forHTTPHeaderField: "X-Plex-Token")
        return request
    }

    /// Turn a Plex relative path into a tokenised absolute URL against `base`.
    /// `X-Plex-Token` goes in the query because `AsyncImage` / `AVPlayer` can't
    /// set headers; Plex accepts the token in either position.
    nonisolated func tokenisedURL(base: URL, path relativePath: String?) -> URL? {
        guard let relativePath, !relativePath.isEmpty else { return nil }
        let combined = base.appendingPathComponent(relativePath)
        guard var components = URLComponents(url: combined, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var query = components.queryItems ?? []
        query.append(URLQueryItem(name: "X-Plex-Token", value: accessToken))
        components.queryItems = query
        return components.url
    }
}

public enum PlexConnectionError: Error, Sendable, Equatable {
    case noReachableConnection
}
