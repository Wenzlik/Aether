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

    /// Structured logging for the PUT-then-decide pipeline. Lives in
    /// Console.app / `log stream --predicate 'subsystem == "cz.zmrhal.aether"'`.
    /// **Never logs the X-Plex token or full URLs** — only host, paths, query
    /// keys, decision verdicts. Use it to debug `Quality = Original` 400s and
    /// transcode session mismatches without leaking secrets.
    private static let log = Logger(subsystem: "cz.zmrhal.aether", category: "plex.playback")

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
            URLQueryItem(name: "sort", value: sort.plexParameter),
            // Plex omits the `Guid` array (TMDB/IMDB/TVDB) from list responses
            // unless asked. Without it, Unified Library can't dedup the same film
            // across Plex/Jellyfin and falls back to title+year (which breaks on
            // localized titles) → duplicates. `includeGuids=1` brings the IDs.
            URLQueryItem(name: "includeGuids", value: "1")
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

    // MARK: - Audio-language filter (#295)

    public nonisolated var supportsAudioLanguageFilter: Bool { true }

    /// Plex's available audio-language filter values for a section
    /// (`GET /library/sections/{id}/audioLanguage` → `Directory` key/title).
    /// `key` is the language code Plex also accepts as `?audioLanguage=`.
    public func audioLanguageOptions(in libraryID: Library.ID) async -> [String] {
        guard let base = try? await resolveBaseURL() else { return [] }
        let request = request(base: base, path: "/library/sections/\(libraryID.rawValue)/audioLanguage")
        guard let response = try? await api.decode(
            PlexAPI.DirectoryListResponse.self, from: request, decoder: decoder
        ) else { return [] }
        return (response.mediaContainer.directories ?? []).map(\.key)
    }

    /// Server-side audio-language filtered listing
    /// (`/library/sections/{id}/all?audioLanguage={code}`). Plex matches the code
    /// against any audio stream on the title, which is exactly the capability
    /// filter #295 wants.
    public func items(in libraryID: Library.ID, audioLanguage code: String) async throws -> [MediaItem]? {
        let base = try await resolveBaseURL()
        let request = request(
            base: base,
            path: "/library/sections/\(libraryID.rawValue)/all",
            queryItems: [
                URLQueryItem(name: "audioLanguage", value: code),
                URLQueryItem(name: "includeGuids", value: "1")
            ]
        )
        let response = try await api.decode(
            PlexAPI.LibraryItemsResponse.self, from: request, decoder: decoder
        )
        return (response.mediaContainer.metadata ?? []).map { mapMetadataToMediaItem($0, base: base) }
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
        // includeImages exposes the Image[] array (clearLogo etc.) on PMS
        // versions that gate it behind the flag; harmless where it's default.
        let request = request(
            base: base,
            path: "/library/metadata/\(id.rawValue)",
            queryItems: [URLQueryItem(name: "includeImages", value: "1")]
        )
        let response = try await api.decode(
            PlexAPI.LibraryItemsResponse.self,
            from: request,
            decoder: decoder
        )
        return response.mediaContainer.metadata?.first.map { mapMetadataToMediaItem($0, base: base) }
    }

    /// Skip segments from Plex intro / credits markers. Markers are only
    /// returned with `includeMarkers=1` on the detail endpoint. Returns `[]`
    /// when the server hasn't generated markers — skip controls stay hidden.
    public func segments(for id: MediaID) async -> [PlaybackSegment] {
        guard id.source == self.id, let base = try? await resolveBaseURL() else { return [] }
        let request = request(
            base: base,
            path: "/library/metadata/\(id.rawValue)",
            queryItems: [URLQueryItem(name: "includeMarkers", value: "1")]
        )
        guard let response = try? await api.decode(
            PlexAPI.LibraryItemsResponse.self, from: request, decoder: decoder
        ) else { return [] }
        return response.mediaContainer.metadata?.first?.segments ?? []
    }

    /// Similar titles from Plex's related hubs (`/hubs/metadata/{id}/related`).
    /// Flattens every hub, drops the item itself + duplicates, and maps to
    /// `MediaItem`. Best-effort: `[]` on any failure, so the rail stays hidden.
    public func related(to id: MediaID) async -> [MediaItem] {
        guard id.source == self.id, let base = try? await resolveBaseURL() else { return [] }
        let request = request(base: base, path: "/hubs/metadata/\(id.rawValue)/related")
        guard let response = try? await api.decode(
            PlexAPI.RelatedHubsResponse.self, from: request, decoder: decoder
        ) else { return [] }

        var seen: Set<String> = [id.rawValue]
        var items: [MediaItem] = []
        for hub in response.mediaContainer.hub ?? [] {
            for dto in hub.metadata ?? [] where seen.insert(dto.ratingKey).inserted {
                items.append(mapMetadataToMediaItem(dto, base: base))
            }
        }
        return items
    }

    // MARK: - Library facets (#273)

    public nonisolated var supportsCollections: Bool { true }
    public nonisolated var supportsPeople: Bool { true }

    /// Every collection across the movie + show sections. Collections come back
    /// as `Metadata` entries (`type: "collection"`, `childCount`) — mapped
    /// directly to `MediaCollection`, never through `mapMetadataToMediaItem`
    /// (whose kind fallback would fake them as movies).
    public func collections() async -> [MediaCollection] {
        guard let base = try? await resolveBaseURL(),
              let sections = try? await libraries() else { return [] }
        var seen: Set<String> = []
        var result: [MediaCollection] = []
        for section in sections {
            // Servers disagree on which endpoint lists collections: the dedicated
            // `/sections/{id}/collections` vs the `all?type=18` (type 18 =
            // *collection*) listing. Both returned empty on the reporter's Plex
            // while Jellyfin worked (#298), so query BOTH, merge + dedupe by
            // ratingKey, and log each endpoint's count (token-safe) so a real
            // server/API gap can't masquerade as "no collections".
            let endpoints: [(path: String, query: [URLQueryItem])] = [
                ("/library/sections/\(section.id.rawValue)/collections", []),
                ("/library/sections/\(section.id.rawValue)/all", [URLQueryItem(name: "type", value: "18")]),
            ]
            for endpoint in endpoints {
                let request = request(base: base, path: endpoint.path, queryItems: endpoint.query)
                do {
                    let response = try await api.decode(
                        PlexAPI.LibraryItemsResponse.self, from: request, decoder: decoder
                    )
                    let dtos = response.mediaContainer.metadata ?? []
                    Self.log.info("Plex collections \(endpoint.path, privacy: .public): \(dtos.count, privacy: .public) found")
                    for dto in dtos where seen.insert(dto.ratingKey).inserted {
                        result.append(MediaCollection(
                            id: .init(source: id, rawValue: dto.ratingKey),
                            title: dto.title,
                            childCount: dto.childCount,
                            artwork: ArtworkSource(
                                provider: .plex, base: base, token: accessToken,
                                posterPath: dto.thumb, backdropPath: dto.art
                            )
                        ))
                    }
                } catch {
                    Self.log.error("Plex collections \(endpoint.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        return result.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    public func items(inCollection collectionID: MediaID) async -> [MediaItem] {
        guard collectionID.source == self.id,
              let base = try? await resolveBaseURL() else { return [] }
        let request = request(
            base: base,
            path: "/library/collections/\(collectionID.rawValue)/children",
            queryItems: [URLQueryItem(name: "includeGuids", value: "1")]
        )
        guard let response = try? await api.decode(
            PlexAPI.LibraryItemsResponse.self, from: request, decoder: decoder
        ) else { return [] }
        return (response.mediaContainer.metadata ?? []).map { mapMetadataToMediaItem($0, base: base) }
    }

    /// People from the per-section secondary directories (`/actor`, `/director`),
    /// deduped by tag id across sections.
    public func people(_ kind: PersonKind) async -> [MediaPerson] {
        guard let base = try? await resolveBaseURL(),
              let sections = try? await libraries() else { return [] }
        let directory = kind == .actor ? "actor" : "director"
        var seen: Set<String> = []
        var result: [MediaPerson] = []
        for section in sections {
            let request = request(base: base, path: "/library/sections/\(section.id.rawValue)/\(directory)")
            guard let response = try? await api.decode(
                PlexAPI.DirectoryListResponse.self, from: request, decoder: decoder
            ) else { continue }
            for entry in response.mediaContainer.directories ?? [] where seen.insert(entry.key).inserted {
                result.append(MediaPerson(
                    id: .init(source: id, rawValue: entry.key),
                    kind: kind,
                    name: entry.title,
                    artwork: entry.thumb.map {
                        ArtworkSource(provider: .plex, base: base, token: accessToken,
                                      posterPath: $0, backdropPath: nil)
                    }
                ))
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Every title featuring the person — `/all?actor={tagID}` (or `director=`)
    /// per section, aggregated.
    public func items(withPerson person: MediaPerson) async -> [MediaItem] {
        guard person.id.source == self.id,
              let base = try? await resolveBaseURL(),
              let sections = try? await libraries() else { return [] }
        let filterName = person.kind == .actor ? "actor" : "director"
        var seen: Set<String> = []
        var result: [MediaItem] = []
        for section in sections {
            let request = request(
                base: base,
                path: "/library/sections/\(section.id.rawValue)/all",
                queryItems: [
                    URLQueryItem(name: filterName, value: person.id.rawValue),
                    URLQueryItem(name: "includeGuids", value: "1"),
                ]
            )
            guard let response = try? await api.decode(
                PlexAPI.LibraryItemsResponse.self, from: request, decoder: decoder
            ) else { continue }
            for dto in response.mediaContainer.metadata ?? [] where seen.insert(dto.ratingKey).inserted {
                result.append(mapMetadataToMediaItem(dto, base: base))
            }
        }
        return result
    }

    /// Build a fresh playback URL for the request, mirroring Plex Web:
    ///
    /// 1. **PUT** `/library/parts/{partId}?audioStreamID=…&subtitleStreamID=…`
    ///    so the chosen streams become the Part's canonical selection on the
    ///    server. URL-only stream selection (the old approach) raced with
    ///    server-side Part state and explained the audio-switch unreliability.
    /// 2. **GET** `/video/:/transcode/universal/decision?…` so the *server*
    ///    decides Direct Play vs Direct Stream vs Transcode. Plex Web does this
    ///    on every play — skipping it is why pause-and-resume sometimes hit
    ///    `400` + `EXTM3U=false`.
    /// 3. Build the playback URL based on the decision: a direct file URL for
    ///    Direct Play, a `start.m3u8` URL for Direct Stream / Transcode.
    /// 4. Warm up HLS playlists before returning so AVPlayer never sees a cold
    ///    URL.
    ///
    /// Every step uses a brand-new transcode session id so a reaped session
    /// can't resurface as `-1008` on resume / track switch.
    public func resolvePlayback(_ request: PlaybackRequest) async throws -> ResolvedPlayback {
        // No Plex part to drive PUT-then-decide → fall back to whatever URL the
        // caller already had. Used by sources without a Part concept and by
        // pre-decision tests.
        guard request.partID != nil else {
            return try await resolveLegacyPlayback(request)
        }

        let base = try await resolveBaseURL()
        let isLocal = resolvedIsLocal
        let rawOffset = request.startTime.map(Self.seconds(_:)).map { max(0, $0) } ?? 0

        // 1. PUT the user's stream selection (no-op if nothing to set).
        try await applyStreamSelection(
            base: base,
            partID: request.partID!,
            audioStreamID: request.audioStreamID,
            subtitleStreamID: request.subtitleStreamID
        )

        // 2. Ask the server for a decision. Session id is shared between the
        // decision call and the start.m3u8 call so Plex pairs them correctly.
        let sessionID = await sessionManager.newSessionID()
        let decision: PlexDecision
        do {
            decision = try await fetchDecision(
                base: base,
                ratingKey: request.itemID.rawValue,
                audioStreamID: request.audioStreamID,
                subtitleStreamID: request.subtitleStreamID,
                quality: request.quality,
                sessionID: sessionID,
                location: isLocal ? "lan" : nil
            )
        } catch {
            Self.log.error(
                """
                decision FAILED quality=\(request.quality.rawValue, privacy: .public) \
                ratingKey=\(request.itemID.rawValue, privacy: .public) \
                error=\(String(describing: error), privacy: .public)
                """
            )
            throw error
        }
        Self.log.notice(
            """
            decision quality=\(request.quality.rawValue, privacy: .public) \
            directPlayAllowed=\(request.quality.allowsDirectPlay, privacy: .public) \
            mode=\(decision.mode.rawValue, privacy: .public) \
            verdict=\(decision.rawDecision ?? "-", privacy: .public) \
            codec=\(decision.videoCodec ?? "-", privacy: .public)/\(decision.audioCodec ?? "-", privacy: .public) \
            res=\(decision.videoResolution ?? "-", privacy: .public) \
            container=\(decision.container ?? "-", privacy: .public)
            """
        )

        // 3. Build the playback URL.
        if decision.mode == .directPlay,
           let directURL = directPlayURL(
               base: base,
               partID: request.partID!,
               filename: decision.partFilename
           ) {
            Self.log.notice("play mode=directPlay path=\(directURL.path, privacy: .public)")
            // Direct play: client opens the original file, seeks itself.
            return ResolvedPlayback(
                url: directURL,
                isServerTranscode: false,
                baseOffsetSeconds: 0,
                clientSeekSeconds: rawOffset > 0 ? rawOffset : nil,
                transcodeSessionID: nil,
                decision: .directPlay
            )
        }

        // Direct stream or transcode → HLS via universal transcoder. If the
        // decision said directplay but we couldn't extract a file URL from the
        // response, we deliberately fall through here with a transcode-shaped
        // request rather than hand AVPlayer a half-built directplay URL.
        let effectiveMode: PlaybackDecisionMode = (decision.mode == .directPlay)
            ? .directStream    // server agreed to DP, but we can't open it client-side
            : decision.mode
        let bakeOffset = rawOffset > Self.smallOffsetThreshold
        guard let url = transcodeStartURL(
            base: base,
            ratingKey: request.itemID.rawValue,
            audioStreamID: request.audioStreamID,
            subtitleStreamID: request.subtitleStreamID,
            quality: request.quality,
            offsetSeconds: bakeOffset ? rawOffset : nil,
            sessionID: sessionID,
            location: isLocal ? "lan" : nil
        ) else {
            throw PlaybackResolveError.noPlayableStream
        }
        Self.log.notice(
            """
            play mode=\(effectiveMode.rawValue, privacy: .public) \
            quality=\(request.quality.rawValue, privacy: .public) \
            offset=\(Int(rawOffset), privacy: .public)s \
            bakedOffset=\(bakeOffset, privacy: .public)
            """
        )

        // 4. Warm up the playlist.
        let outcome = await sessionManager.warmUp(warmUpRequest(for: url), delays: warmUpBackoff)
        guard outcome.ready else {
            Self.log.error(
                """
                warm-up FAILED quality=\(request.quality.rawValue, privacy: .public) \
                mode=\(effectiveMode.rawValue, privacy: .public) \
                attempts=\(outcome.attempts, privacy: .public) \
                lastStatus=\(outcome.lastStatus ?? -1, privacy: .public) \
                sawEXTM3U=\(outcome.sawPlaylistMarker, privacy: .public)
                """
            )
            throw PlaybackResolveError.notReady(diagnostics: Self.diagnostics(
                isLocal: isLocal, base: base, sessionID: sessionID, offset: rawOffset,
                audioStreamID: request.audioStreamID, subtitleStreamID: request.subtitleStreamID,
                outcome: outcome
            ))
        }
        await sessionManager.markActive(sessionID)

        return ResolvedPlayback(
            url: url,
            isServerTranscode: true,
            baseOffsetSeconds: bakeOffset ? rawOffset : 0,
            clientSeekSeconds: (!bakeOffset && rawOffset > 0) ? rawOffset : nil,
            transcodeSessionID: sessionID,
            decision: effectiveMode
        )
    }

    /// Pre-pipeline fallback for requests with no `partID` (mock items, legacy
    /// tests). Kept narrow so the new flow is the default for anything that
    /// actually came from a Plex server.
    private func resolveLegacyPlayback(_ request: PlaybackRequest) async throws -> ResolvedPlayback {
        switch request.mode {
        case .directPlay:
            guard let url = request.directPlayURL else {
                throw PlaybackResolveError.noPlayableStream
            }
            return ResolvedPlayback(url: url, isServerTranscode: false, baseOffsetSeconds: 0)
        case .transcode:
            let base = try await resolveBaseURL()
            let sessionID = await sessionManager.newSessionID()
            let rawOffset = request.startTime.map(Self.seconds(_:)).map { max(0, $0) } ?? 0
            let bakeOffset = rawOffset > Self.smallOffsetThreshold
            guard let url = transcodeStartURL(
                base: base,
                ratingKey: request.itemID.rawValue,
                audioStreamID: request.audioStreamID,
                subtitleStreamID: request.subtitleStreamID,
                quality: request.quality,
                offsetSeconds: bakeOffset ? rawOffset : nil,
                sessionID: sessionID,
                location: resolvedIsLocal ? "lan" : nil
            ) else {
                throw PlaybackResolveError.noPlayableStream
            }
            let outcome = await sessionManager.warmUp(warmUpRequest(for: url), delays: warmUpBackoff)
            guard outcome.ready else {
                throw PlaybackResolveError.notReady(diagnostics: Self.diagnostics(
                    isLocal: resolvedIsLocal, base: base, sessionID: sessionID, offset: rawOffset,
                    audioStreamID: request.audioStreamID, subtitleStreamID: request.subtitleStreamID,
                    outcome: outcome
                ))
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

    // MARK: - Pipeline steps

    /// `PUT /library/parts/{partId}?audioStreamID=…&subtitleStreamID=…`.
    ///
    /// Persists the user's stream choice as the Part's canonical selection.
    /// Plex's running metadata then reports the chosen streams with
    /// `selected="1"`, which is what makes audio-switching reliable: the
    /// transcode session reads its selection from the Part, not from URL
    /// params that may or may not stick.
    ///
    /// No-op when no IDs are supplied (e.g. user opened Detail and pressed
    /// Play without touching the pickers — server keeps its default).
    func applyStreamSelection(
        base: URL,
        partID: String,
        audioStreamID: String?,
        subtitleStreamID: String?
    ) async throws {
        var items: [URLQueryItem] = []
        if let audioStreamID { items.append(URLQueryItem(name: "audioStreamID", value: audioStreamID)) }
        if let subtitleStreamID { items.append(URLQueryItem(name: "subtitleStreamID", value: subtitleStreamID)) }
        guard !items.isEmpty else { return }

        var request = self.request(base: base, path: "/library/parts/\(partID)", queryItems: items)
        request.httpMethod = "PUT"
        let (_, response) = try await api.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw APIClientError.unexpectedStatus(response.statusCode)
        }
    }

    /// `GET /video/:/transcode/universal/decision?…`.
    ///
    /// Mirrors Plex Web's pre-flight: send the same params we'd send to
    /// `start.m3u8`, then read back `Media.Part.decision` ("directplay",
    /// "directstream", "transcode") so the source layer can build the right
    /// URL. We also surface post-decision codecs / bitrate / resolution and
    /// the Part filename (needed to construct the direct-play URL).
    func fetchDecision(
        base: URL,
        ratingKey: String,
        audioStreamID: String?,
        subtitleStreamID: String?,
        quality: PlaybackQuality,
        sessionID: String,
        location: String?
    ) async throws -> PlexDecision {
        let request = self.request(
            base: base,
            path: "/video/:/transcode/universal/decision",
            queryItems: decisionQueryItems(
                ratingKey: ratingKey,
                audioStreamID: audioStreamID,
                subtitleStreamID: subtitleStreamID,
                quality: quality,
                sessionID: sessionID,
                location: location
            )
        )
        // Read the raw response so a non-2xx (the dreaded decision 400) surfaces
        // Plex's own error message in the log instead of a bare status code —
        // that body is the only reliable way to learn *why* a decision failed.
        let (data, http) = try await api.data(for: request)
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count)B>"
            Self.log.error("decision HTTP \(http.statusCode, privacy: .public) body=\(body, privacy: .public)")
            throw APIClientError.unexpectedStatus(http.statusCode)
        }
        let response = try decoder.decode(PlexAPI.DecisionResponse.self, from: data)
        return PlexDecision(from: response)
    }

    /// Query items for the decision call.
    ///
    /// For `.original` quality we now send `directPlay=1` alongside
    /// `X-Plex-Client-Profile-Extra` — a capability profile that tells Plex
    /// exactly which containers and codecs Aether handles natively (VLCKit on
    /// iOS/tvOS, libmpv on macOS). This unlocks true direct play for MKV/HEVC/DTS
    /// files: Plex serves the raw file, no server CPU spent on remuxing.
    ///
    /// For all other qualities `directPlay=0` is kept — those requests have a
    /// bitrate or resolution cap in mind, so transcoding is intentional.
    ///
    /// `start.m3u8` always stays `directPlay=0` regardless (see
    /// `transcodeStartURL` — direct play is a file URL, not a transcoder path).
    private func decisionQueryItems(
        ratingKey: String,
        audioStreamID: String?,
        subtitleStreamID: String?,
        quality: PlaybackQuality,
        sessionID: String,
        location: String?
    ) -> [URLQueryItem] {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "path", value: "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "protocol", value: "hls"),
            URLQueryItem(name: "hasMDE", value: "1"),
            URLQueryItem(name: "mediaIndex", value: "0"),
            URLQueryItem(name: "partIndex", value: "0"),
            URLQueryItem(name: "directPlay", value: "0"),
            URLQueryItem(name: "directStream", value: "1"),
            URLQueryItem(name: "fastSeek", value: "1"),
            URLQueryItem(name: "videoQuality", value: "100"),
            URLQueryItem(name: "session", value: sessionID),
            URLQueryItem(name: "X-Plex-Session-Identifier", value: sessionID),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: configuration.clientIdentifier),
            URLQueryItem(name: "X-Plex-Product", value: configuration.product),
            URLQueryItem(name: "X-Plex-Platform", value: configuration.platform),
            URLQueryItem(name: "X-Plex-Token", value: accessToken)
        ]
        // directPlay is intentionally hard-wired to 0 even for .original quality.
        // Sending directPlay=1 causes Plex to return HTTP 400 from the decision
        // endpoint on many server configs. directStream=1 covers the "original
        // quality" intent: Plex remuxes without re-encoding when codecs match,
        // which is lossless. True file-URL direct play is handled via
        // directPlayURL() after a successful directplay decision.
        if let maxKbps = quality.maxVideoBitrateKbps {
            items.append(URLQueryItem(name: "maxVideoBitrate", value: String(maxKbps)))
        }
        if let resolution = quality.videoResolution {
            items.append(URLQueryItem(name: "videoResolution", value: resolution))
        }
        if let audioStreamID {
            items.append(URLQueryItem(name: "audioStreamID", value: audioStreamID))
        }
        if let subtitleStreamID {
            items.append(URLQueryItem(name: "subtitleStreamID", value: subtitleStreamID))
        }
        if let location {
            items.append(URLQueryItem(name: "location", value: location))
        }
        return items
    }

    /// Build the direct-play file URL for a Part. The Part's `key` already
    /// includes the timestamp segment Plex needs in the path; we just tokenise.
    func directPlayURL(base: URL, partID: String, filename: String?) -> URL? {
        // Plex's direct file path is `/library/parts/{partId}/{ts}/{filename}`,
        // but the `key` Plex returned on the Part already encodes all three.
        // When the decision endpoint surfaces a Part `file` path, prefer it;
        // otherwise we can't direct-play (which is fine — fall back to HLS).
        guard let filename, !filename.isEmpty else { return nil }
        return tokenisedURL(base: base, path: filename)
    }

    /// Stop a transcode session on the server (`/transcode/universal/stop`).
    public func stopTranscode(sessionID: String) async {
        guard let base = resolvedBaseURL, let url = stopURL(base: base, sessionID: sessionID) else { return }
        var request = URLRequest(url: url)
        for (key, value) in configuration.commonHeaders { request.setValue(value, forHTTPHeaderField: key) }
        await sessionManager.stop(request, sessionID: sessionID)
    }

    /// Plex always supports downloads via the progressive-MP4 transcode
    /// endpoint. Synchronous flag so Detail's Download button visibility
    /// is decided at view-render time without an actor hop.
    public nonisolated var supportsDownloads: Bool { true }

    /// Drop any cached connection so the next request re-probes against the
    /// ranked list. Called by `downloadURL(for:quality:)` so a download
    /// queued after the user moved off LAN doesn't try to hit the stale
    /// LAN URL.
    private func invalidateConnectionForFreshProbe() {
        resolvedBaseURL = nil
        resolvedIsLocal = false
    }

    /// Build a download URL for an item — a progressive-MP4 transcode the
    /// `DownloadManager`'s background `URLSession` can pull in one big GET.
    ///
    /// Phase 2.0 uses the universal-transcoder endpoint with
    /// `protocol=http` (instead of `protocol=hls`) for **every** quality,
    /// including Original. That means the server transcodes / remuxes even
    /// when the source container is directly downloadable (mp4 / mov / m4v
    /// could be GET'd raw). Tradeoff: simpler one-path implementation, at
    /// the cost of some server CPU for direct-playable Originals. A future
    /// optimisation will route Original-quality + AVPlayer-friendly
    /// containers through the raw Part URL.
    public func downloadURL(for item: MediaItem, quality: PlaybackQuality) async throws -> URL? {
        guard item.id.source == self.id else { return nil }
        // Force a fresh probe: the user might have moved off LAN between
        // the last library fetch and pressing Download. Cached LAN URLs
        // would resolve to a dead 192.168.x.x host that
        // URLSession.background can't recover from. The probe takes
        // ~probeTimeout per dead candidate but is bounded by the
        // connection list (typically 3-5 candidates).
        invalidateConnectionForFreshProbe()
        let base = try await resolveBaseURL()

        // Prefer the raw Part file URL for Original quality — same path
        // Plex Web's Download button uses (`?download=1` flag turns the
        // response into a Content-Disposition attachment). This avoids
        // the universal-transcoder endpoint entirely; the server just
        // serves the file from disk. Critically, this works through
        // Plex's remote endpoints where `/transcode/universal/start?
        // protocol=http` returns HTTP 400.
        if quality == .original, let fileURL = item.originalFileURL,
           let rebased = rebaseTokenisedURL(fileURL, to: base) {
            return appendingQueryItem(rebased, name: "download", value: "1")
        }
        var components = URLComponents(
            url: base.appendingPathComponent("/video/:/transcode/universal/start"),
            resolvingAgainstBaseURL: false
        )
        var queryItems = [
            URLQueryItem(name: "path", value: "/library/metadata/\(item.id.rawValue)"),
            // The key difference from `transcodeStartURL`: `protocol=http`
            // makes Plex emit a single progressive MP4 stream instead of an
            // HLS playlist. `URLSessionDownloadTask` can pull it in one
            // request and save it as a movable file.
            URLQueryItem(name: "protocol", value: "http"),
            URLQueryItem(name: "container", value: "mp4"),
            URLQueryItem(name: "directPlay", value: "0"),
            URLQueryItem(name: "directStream", value: "1"),
            URLQueryItem(name: "fastSeek", value: "1"),
            URLQueryItem(name: "mediaIndex", value: "0"),
            URLQueryItem(name: "partIndex", value: "0"),
            URLQueryItem(name: "videoQuality", value: "100"),
            // Each download gets a fresh transcoder session so a stuck job
            // can't poison subsequent attempts.
            URLQueryItem(name: "session", value: UUID().uuidString),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: configuration.clientIdentifier),
            URLQueryItem(name: "X-Plex-Product", value: configuration.product),
            URLQueryItem(name: "X-Plex-Platform", value: configuration.platform),
            URLQueryItem(name: "X-Plex-Token", value: accessToken)
        ]
        if let maxKbps = quality.maxVideoBitrateKbps {
            queryItems.append(URLQueryItem(name: "maxVideoBitrate", value: String(maxKbps)))
        }
        if let resolution = quality.videoResolution {
            queryItems.append(URLQueryItem(name: "videoResolution", value: resolution))
        }
        if let audioStreamID = item.selectedAudioTrackID {
            queryItems.append(URLQueryItem(name: "audioStreamID", value: audioStreamID))
        }
        if let subtitleStreamID = item.selectedSubtitleTrackID {
            queryItems.append(URLQueryItem(name: "subtitleStreamID", value: subtitleStreamID))
        }
        if resolvedIsLocal {
            queryItems.append(URLQueryItem(name: "location", value: "lan"))
        }
        components?.queryItems = queryItems
        return components?.url
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

    // MARK: - Connection resolution + failover

    /// Return a reachable connection's base URL, probing `/identity` in ranked
    /// order. The first success is cached for the rest of the session.
    /// Throws `PlexConnectionError.noReachableConnection` when every candidate
    /// fails (e.g. server offline, or off-network with no remote connection).
    ///
    /// Logs every candidate's verdict to the playback log so off-LAN issues
    /// can be diagnosed without a debugger: if the user's resource list has
    /// only LAN (no relay / no remote), the log shows that explicitly —
    /// the fix is server-side (enable Plex Remote Access).
    func resolveBaseURL() async throws -> URL {
        if let resolvedBaseURL { return resolvedBaseURL }

        Self.log.notice(
            "resolveBaseURL probing candidates=\(self.connections.count, privacy: .public) local=\(self.connections.filter { $0.isLocal }.count, privacy: .public) relay=\(self.connections.filter { $0.isRelay }.count, privacy: .public)"
        )

        for connection in connections {
            guard let base = connection.url else { continue }
            let kind = connection.isLocal ? "lan" : (connection.isRelay ? "relay" : "remote")
            let host = base.host ?? "?"
            let reachable = await isReachable(base)
            Self.log.notice(
                "  candidate kind=\(kind, privacy: .public) host=\(host, privacy: .public) reachable=\(reachable, privacy: .public)"
            )
            if reachable {
                resolvedBaseURL = base
                resolvedIsLocal = connection.isLocal
                return base
            }
        }

        // No candidate worked. Diagnose for the user: an "only LAN" list
        // means Remote Access isn't enabled on the server — we can't fix
        // that from the client.
        let hasRemote = connections.contains { !$0.isLocal && !$0.isRelay }
        let hasRelay = connections.contains { $0.isRelay }
        Self.log.error(
            "no reachable connection. lanOnly=\(!hasRemote && !hasRelay, privacy: .public) hasRelay=\(hasRelay, privacy: .public) hasRemote=\(hasRemote, privacy: .public)"
        )
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
        // Audio / subtitle pickers live on Detail and apply across both
        // direct-play and transcoded sessions now: when the user changes a
        // track, the source PUTs the selection to the Part and the next
        // decision call returns whatever mode fits. So we surface tracks
        // whenever they're present, not only for items that happen to default
        // to transcode.
        let audioTracks = dto.audioTracks
        let subtitleTracks = dto.subtitleTracks
        // Artwork as a tier-aware source; the baked poster/backdrop below are its
        // default tiers, and the Detail hero can ask it for a larger backdrop.
        let artwork = ArtworkSource(
            provider: .plex, base: base, token: accessToken,
            posterPath: dto.thumb, backdropPath: dto.art,
            // clearLogo from the Image[] entries (detail endpoint). Match is
            // case-insensitive to hedge PMS-version casing differences.
            logoPath: dto.images?.first {
                $0.type?.caseInsensitiveCompare("clearLogo") == .orderedSame
            }?.url
        )
        // Cast & Crew (Plex `Role`). Headshots go through the same photo
        // transcoder as posters via an ArtworkSource pinned to the role thumb.
        let cast: [CastMember] = (dto.roles ?? []).prefix(20).enumerated().compactMap { index, role in
            guard let name = role.tag?.nonEmptyTrimmed else { return nil }
            let photoURL = role.thumb?.nonEmptyTrimmed.flatMap {
                ArtworkSource(provider: .plex, base: base, token: accessToken,
                              posterPath: $0, backdropPath: nil).posterURL(.thumbnail)
            }
            return CastMember(id: "\(index)-\(name)", name: name,
                              role: role.role?.nonEmptyTrimmed, photoURL: photoURL,
                              personID: role.id.map(String.init))
        }
        return MediaItem(
            id: .init(source: id, rawValue: dto.ratingKey),
            title: dto.title,
            kind: dto.kind,
            year: dto.year,
            runtime: dto.duration.map { .seconds(Double($0) / 1000.0) },
            summary: dto.summary,
            // Server-side resized via /photo/:/transcode — a 400-px poster /
            // ~1200-px backdrop instead of the full-resolution original.
            posterURL: artwork.posterURL(.thumbnail),
            backdropURL: artwork.backdropURL(.backdrop),
            streamURL: streamURL,
            audioTracks: audioTracks,
            selectedAudioTrackID: audioTracks.first(where: \.isSelected)?.id,
            subtitleTracks: subtitleTracks,
            selectedSubtitleTrackID: subtitleTracks.first(where: \.isSelected)?.id,
            partID: dto.firstPartID,
            // Always the raw Part file URL — the source-of-truth file the
            // server has on disk. Same shape Plex Web uses for its download
            // button. Independent of `streamURL`, which may be a transcode
            // placeholder for unfriendly containers.
            originalFileURL: tokenisedURL(base: base, path: dto.firstPartKey),
            mediaInfo: dto.sourceMediaInfo,
            // Episode context — populated from grandparentTitle /
            // parentIndex / index when the DTO is an episode. Movies
            // leave these nil; `displayTitle` collapses gracefully.
            seriesTitle: dto.grandparentTitle,
            // For a season, its *own* `index` is the season number; for an
            // episode, the season number is the parent's `index` and the episode
            // number is its own `index`. (Using `parentIndex` for a season gave
            // every season "Season 1" — the show's index — in the selector.)
            seasonNumber: dto.kind == .season ? dto.index : dto.parentIndex,
            episodeNumber: dto.kind == .episode ? dto.index : nil,
            selectedQuality: .original,
            guids: dto.guids,
            // Plex marks an item watched via `viewCount` (>= 1 play).
            isWatched: (dto.viewCount ?? 0) > 0,
            // Season ratingKey → the id Auto-Play-Next pulls siblings from.
            parentID: dto.parentRatingKey.map { MediaID(source: id, rawValue: $0) },
            genres: dto.genres,
            cast: cast,
            communityRating: dto.audienceRating ?? dto.rating,
            contentRating: dto.contentRating?.nonEmptyTrimmed,
            releaseDate: dto.releaseDate,
            dateAdded: dto.dateAdded,
            seasonCount: dto.childCount,
            episodeCount: dto.leafCount,
            endYear: nil,   // Plex doesn't expose a series end year on list/detail
            isContinuing: nil,
            unwatchedEpisodeCount: dto.unwatchedLeafCount,
            artwork: artwork
        )
    }

    // MARK: - Watch state

    /// Mark watched on the server via Plex's scrobble endpoint, so the play
    /// state syncs to Plex (and every other client). Best-effort: a failed
    /// scrobble is swallowed so it never disrupts playback teardown.
    public func markWatched(_ id: MediaID) async {
        guard id.source == self.id, let base = try? await resolveBaseURL() else { return }
        let request = request(
            base: base,
            path: "/:/scrobble",
            queryItems: [
                URLQueryItem(name: "key", value: id.rawValue),
                URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library")
            ]
        )
        _ = try? await api.data(for: request)
    }

    /// Mark unwatched on the server via Plex's unscrobble endpoint.
    public func markUnwatched(_ id: MediaID) async {
        guard id.source == self.id, let base = try? await resolveBaseURL() else { return }
        let request = request(
            base: base,
            path: "/:/unscrobble",
            queryItems: [
                URLQueryItem(name: "key", value: id.rawValue),
                URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library")
            ]
        )
        _ = try? await api.data(for: request)
    }

    /// Report the playhead to Plex via the timeline endpoint, so resume progress
    /// syncs to Plex and every other client. `time` / `duration` are in
    /// milliseconds; `state` is `playing` / `paused` / `stopped`. Best-effort:
    /// a failed report is swallowed so it never disrupts playback teardown.
    public func recordProgress(_ id: MediaID, position: Duration, duration: Duration?, paused: Bool) async {
        guard id.source == self.id, let base = try? await resolveBaseURL() else { return }
        func ms(_ d: Duration) -> Int { Int((Self.seconds(d) * 1000).rounded()) }
        var items = [
            URLQueryItem(name: "ratingKey", value: id.rawValue),
            URLQueryItem(name: "key", value: "/library/metadata/\(id.rawValue)"),
            URLQueryItem(name: "state", value: paused ? "paused" : "playing"),
            URLQueryItem(name: "time", value: String(ms(position))),
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library")
        ]
        if let duration { items.append(URLQueryItem(name: "duration", value: String(ms(duration)))) }
        let request = request(base: base, path: "/:/timeline", queryItems: items)
        _ = try? await api.data(for: request)
    }

    /// Plex's own On Deck list (`GET /library/onDeck`) as resume points — the
    /// server's curated "Continue Watching", so a fresh device surfaces
    /// in-progress titles/episodes without local history. `viewOffset` is the
    /// playhead (ms); `lastViewedAt` the merge timestamp. Best-effort.
    public func serverResumePoints() async -> [ResumePoint] {
        guard let base = try? await resolveBaseURL() else { return [] }
        let request = request(base: base, path: "/library/onDeck")
        guard let response = try? await api.decode(
            PlexAPI.LibraryItemsResponse.self, from: request, decoder: decoder
        ) else { return [] }
        return (response.mediaContainer.metadata ?? []).compactMap { dto in
            guard let offsetMs = dto.viewOffset, offsetMs > 0 else { return nil }
            let updatedAt = dto.lastViewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date()
            return ResumePoint(
                mediaID: MediaID(source: id, rawValue: dto.ratingKey),
                position: .milliseconds(offsetMs),
                updatedAt: updatedAt
            )
        }
    }

    // MARK: - Stream URL resolution (direct play vs transcode)

    /// Containers AVPlayer opens natively. Anything outside this set goes
    /// through the server transcoder, which always yields playable HLS.
    private static let directPlayContainers: Set<String> = ["mp4", "m4v", "mov"]

    /// Decide the stream URL surfaced on `MediaItem.streamURL` — used purely as
    /// a "this item is playable" flag and as the direct-play file URL for
    /// AVPlayer-friendly containers. The actual playback URL is built at play
    /// time by `resolvePlayback` (PUT → decision → start.m3u8 or direct file).
    nonisolated func streamURL(for dto: PlexAPI.Metadata, base: URL) -> URL? {
        guard dto.firstPartKey != nil else { return nil }

        if let container = dto.firstContainer?.lowercased(),
           Self.directPlayContainers.contains(container) {
            return tokenisedURL(base: base, path: dto.firstPartKey)
        }
        // Unknown or unfriendly container — placeholder transcode URL so the
        // detail view knows the item is playable. The real playback URL is
        // rebuilt by `resolvePlayback` from a decision response.
        return transcodeStartURL(
            base: base,
            ratingKey: dto.ratingKey,
            audioStreamID: dto.selectedAudioTrackID
        )
    }

    /// Build a universal-transcoder HLS URL for an item, post-decision.
    ///
    /// `directPlay` is hard-wired to `0` here on purpose: Plex Web *never*
    /// sends `directPlay=1` to `start.m3u8` — direct play is served straight
    /// from the file URL, not through the transcoder. Asking start.m3u8 to
    /// "please direct play" while it's a transcode endpoint is a contradictory
    /// request and Plex answers with HTTP 400. That was the Tron: Ares /
    /// Original-quality bug: my earlier code mirrored `directPlay=1` from the
    /// decision call onto start.m3u8, and Plex rejected every Original-quality
    /// request that didn't actually resolve to a real direct-play file URL.
    ///
    /// The user's quality choice still influences this URL through bitrate /
    /// resolution caps (when set). Stream IDs ride on both the prior PUT and
    /// the URL as a redundant "honour this for this session" safeguard.
    nonisolated func transcodeStartURL(
        base: URL,
        ratingKey: String,
        audioStreamID: String? = nil,
        subtitleStreamID: String? = nil,
        quality: PlaybackQuality = .original,
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
            // Never `1` here — see the doc comment above. The decision call is
            // where we ask "may we direct play?"; this URL only ever serves
            // transcode / direct stream output.
            URLQueryItem(name: "directPlay", value: "0"),
            URLQueryItem(name: "directStream", value: "1"),
            URLQueryItem(name: "fastSeek", value: "1"),
            URLQueryItem(name: "mediaIndex", value: "0"),
            URLQueryItem(name: "partIndex", value: "0"),
            URLQueryItem(name: "videoQuality", value: "100"),
            URLQueryItem(name: "session", value: session),
            URLQueryItem(name: "X-Plex-Session-Identifier", value: session),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: configuration.clientIdentifier),
            URLQueryItem(name: "X-Plex-Product", value: configuration.product),
            URLQueryItem(name: "X-Plex-Platform", value: configuration.platform),
            URLQueryItem(name: "X-Plex-Token", value: accessToken)
        ]
        if let maxKbps = quality.maxVideoBitrateKbps {
            queryItems.append(URLQueryItem(name: "maxVideoBitrate", value: String(maxKbps)))
        }
        if let resolution = quality.videoResolution {
            queryItems.append(URLQueryItem(name: "videoResolution", value: resolution))
        }
        if let audioStreamID {
            queryItems.append(URLQueryItem(name: "audioStreamID", value: audioStreamID))
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


    /// Re-anchor a tokenised URL onto a different base (host + scheme +
    /// port). The path and query items survive; only the host moves. Used
    /// when `MediaItem.originalFileURL` was tokenised against a LAN base
    /// during library load, but the download needs to go through the
    /// currently-reachable connection (e.g. remote). Falls back to the
    /// original URL if URLComponents can't parse anything.
    nonisolated func rebaseTokenisedURL(_ url: URL, to newBase: URL) -> URL? {
        guard
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let newBaseComponents = URLComponents(url: newBase, resolvingAgainstBaseURL: false)
        else { return url }
        components.scheme = newBaseComponents.scheme
        components.host = newBaseComponents.host
        components.port = newBaseComponents.port
        return components.url
    }

    /// Append or override a single query item on a URL. Plex's
    /// `?download=1` flag is the canonical example — flip from "stream"
    /// to "download" behaviour without rebuilding the URL from scratch.
    nonisolated func appendingQueryItem(_ url: URL, name: String, value: String) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == name }
        items.append(URLQueryItem(name: name, value: value))
        components.queryItems = items
        return components.url
    }
}

public enum PlexConnectionError: Error, Sendable, Equatable {
    case noReachableConnection
}

// MARK: - Decision model

/// Internal model wrapping Plex's `/video/:/transcode/universal/decision`
/// response — what mode the server picked and the post-decision media info we
/// surface on Detail (and use to build the direct-play URL).
struct PlexDecision: Sendable, Equatable {
    let mode: PlaybackDecisionMode
    /// The chosen Part's file path (`key` on the decision response). Needed to
    /// build the direct-play URL when `mode == .directPlay`.
    let partFilename: String?
    let videoCodec: String?
    let audioCodec: String?
    let videoResolution: String?
    let bitrateKbps: Int?
    let container: String?
    /// Plex's raw verdict string (`"directplay"`, `"copy"`, `"transcode"`,
    /// possibly unknown values). Kept for diagnostics — `mode` is the
    /// translated enum, but `rawDecision` is what the log dumps so an
    /// unfamiliar value shows up verbatim in the report.
    let rawDecision: String?

    init(from response: PlexAPI.DecisionResponse) {
        let media = response.mediaContainer.metadata?.first?.media?.first
        let part = media?.part?.first
        self.mode = Self.translate(decision: part?.decision)
        self.partFilename = part?.key ?? part?.file
        self.videoCodec = media?.videoCodec
        self.audioCodec = media?.audioCodec
        self.videoResolution = media?.videoResolution
        self.bitrateKbps = media?.bitrate
        self.container = media?.container
        self.rawDecision = part?.decision
    }

    init(
        mode: PlaybackDecisionMode,
        partFilename: String? = nil,
        videoCodec: String? = nil,
        audioCodec: String? = nil,
        videoResolution: String? = nil,
        bitrateKbps: Int? = nil,
        container: String? = nil,
        rawDecision: String? = nil
    ) {
        self.mode = mode
        self.partFilename = partFilename
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.videoResolution = videoResolution
        self.bitrateKbps = bitrateKbps
        self.container = container
        self.rawDecision = rawDecision
    }

    /// Map Plex's verdict text → our enum. `"copy"` is Plex's name for direct
    /// stream (container remux, no re-encode). Unknown values fall back to
    /// transcode so we don't fail to play.
    private static func translate(decision: String?) -> PlaybackDecisionMode {
        switch decision?.lowercased() {
        case "directplay": return .directPlay
        case "copy":       return .directStream
        case "transcode":  return .transcode
        default:           return .transcode
        }
    }
}
