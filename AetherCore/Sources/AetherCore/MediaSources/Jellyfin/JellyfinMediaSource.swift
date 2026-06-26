import Foundation

/// A Jellyfin server wired up as an Aether `MediaSource`.
///
/// Simpler than `PlexMediaSource` — one base URL the user signed into, no
/// runtime connection probing. Authenticated API calls carry the `MediaBrowser`
/// Authorization header; image + media URLs carry the token as an `api_key`
/// query item (AVPlayer / AsyncImage can't set headers), exactly like Plex
/// tokenises its URLs.
public actor JellyfinMediaSource: MediaSource {
    public let id: MediaSourceID
    public let displayName: String

    private let baseURL: URL
    private let accessToken: String
    private let userID: String
    private let configuration: JellyfinConfiguration
    private let api: any APIClient
    private let decoder: JSONDecoder

    /// Memoized result of the `/Items/Filters2` audio-language capability probe
    /// (#295). `nil` = not yet probed; set once the server gives a definitive
    /// answer. A failed probe stays `nil` so the next filter attempt retries.
    private var cachedAudioFilterSupport: Bool?

    public init(
        serverID: String,
        displayName: String,
        baseURL: URL,
        accessToken: String,
        userID: String,
        configuration: JellyfinConfiguration,
        api: any APIClient
    ) {
        self.id = .jellyfin(serverID: serverID)
        self.displayName = displayName
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.userID = userID
        self.configuration = configuration
        self.api = api
        self.decoder = JSONDecoder()
    }

    // MARK: - MediaSource

    public func libraries() async throws -> [Library] {
        let request = makeRequest(path: "/Users/\(userID)/Views")
        let response = try await api.decode(JellyfinAPI.ItemsResponse.self, from: request, decoder: decoder)
        return response.items.compactMap { dto in
            let kind: MediaItem.Kind
            switch dto.collectionType {
            case "movies":  kind = .movie
            case "tvshows": kind = .show
            default:        return nil   // skip music, photos, etc. (parity with Plex)
            }
            return Library(id: .init(source: id, rawValue: dto.id), title: dto.name ?? "Library", kind: kind)
        }
    }

    public func items(in libraryID: Library.ID) async throws -> [MediaItem] {
        try await items(in: libraryID, sortedBy: .default, limit: nil, offset: nil)
    }

    public func items(
        in libraryID: Library.ID,
        sortedBy sort: LibrarySort,
        limit: Int?,
        offset: Int?
    ) async throws -> [MediaItem] {
        let (sortBy, sortOrder) = Self.jellyfinSort(sort)
        var queryItems = [
            URLQueryItem(name: "ParentId", value: libraryID.rawValue),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"),
            // People is omitted here — 410-item responses with full cast data
            // bloat the payload and cause 30+ second loads. Cast is fetched
            // lazily in the detail view via item(for:) which keeps People.
            URLQueryItem(name: "Fields", value: "Overview,MediaSources,MediaStreams,ProductionYear,ProviderIds,Genres,DateCreated,PremiereDate,EndDate,CommunityRating,ChildCount,RecursiveItemCount,Status,OfficialRating"),
            // Per Jellyfin docs, play state (UserData.Played) comes via this flag,
            // not a `Fields` value — it's the watched-checkmark source.
            URLQueryItem(name: "enableUserData", value: "true"),
            URLQueryItem(name: "SortBy", value: sortBy),
            URLQueryItem(name: "SortOrder", value: sortOrder)
        ]
        if let offset { queryItems.append(URLQueryItem(name: "StartIndex", value: String(offset))) }
        if let limit { queryItems.append(URLQueryItem(name: "Limit", value: String(limit))) }

        let request = makeRequest(path: "/Users/\(userID)/Items", queryItems: queryItems)
        let response = try await api.decode(JellyfinAPI.ItemsResponse.self, from: request, decoder: decoder)
        return response.items.compactMap { mapItem($0) }
    }

    public func children(of id: MediaID) async throws -> [MediaItem] {
        // ParentId returns a show's seasons or a season's episodes uniformly —
        // no need to thread the series id through for the episodes endpoint.
        let request = makeRequest(
            path: "/Users/\(userID)/Items",
            queryItems: [
                URLQueryItem(name: "ParentId", value: id.rawValue),
                URLQueryItem(name: "Fields", value: "Overview,MediaSources,MediaStreams,ProductionYear,ProviderIds,Genres,DateCreated,PremiereDate,EndDate,CommunityRating,ChildCount,RecursiveItemCount,Status,OfficialRating,People"),
                URLQueryItem(name: "enableUserData", value: "true"),
                URLQueryItem(name: "SortBy", value: "SortName"),
                URLQueryItem(name: "SortOrder", value: "Ascending")
            ]
        )
        let response = try await api.decode(JellyfinAPI.ItemsResponse.self, from: request, decoder: decoder)
        return response.items.compactMap { mapItem($0) }
    }

    public func item(for id: MediaID) async throws -> MediaItem? {
        guard id.source == self.id else { return nil }
        let request = makeRequest(
            path: "/Users/\(userID)/Items/\(id.rawValue)",
            queryItems: [
                URLQueryItem(name: "Fields", value: "Overview,MediaSources,MediaStreams,ProductionYear,ProviderIds,Genres,DateCreated,PremiereDate,EndDate,CommunityRating,ChildCount,RecursiveItemCount,Status,OfficialRating,People"),
                URLQueryItem(name: "enableUserData", value: "true")
            ]
        )
        // This endpoint returns a single item, not a wrapped list.
        let dto = try await api.decode(JellyfinAPI.BaseItemDto.self, from: request, decoder: decoder)
        return mapItem(dto)
    }

    // MARK: - Audio-language filter (#295)

    /// Server-side audio-language-filtered listing. Jellyfin gained a real
    /// `?AudioLanguages=` filter in jellyfin/jellyfin#9787 (~10.11.x); on servers
    /// that have it we filter server-side (parity with Plex, and the cheap path
    /// for the Library audio chips' membership queries). Older servers silently
    /// ignore the param and would return an *unfiltered* list dressed up as
    /// filtered — so we gate on a capability probe and return `nil` when it's
    /// unsupported, letting `UnifiedLibrary` fall back to client-side filtering.
    public func items(in libraryID: Library.ID, audioLanguage code: String) async throws -> [MediaItem]? {
        guard await supportsServerAudioFilter() else { return nil }

        // The filter matches the stored 3-letter stream language exactly (OR
        // across the list), so expand the canonical 2-letter key into every
        // variant the server might hold (e.g. cs → cs,ces,cze).
        let values = AudioLanguage.variants(of: code).joined(separator: ",")
        let (sortBy, sortOrder) = Self.jellyfinSort(.default)
        let request = makeRequest(
            path: "/Users/\(userID)/Items",
            queryItems: [
                URLQueryItem(name: "ParentId", value: libraryID.rawValue),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"),
                URLQueryItem(name: "Fields", value: "Overview,MediaSources,MediaStreams,ProductionYear,ProviderIds,Genres,DateCreated,PremiereDate,EndDate,CommunityRating,ChildCount,RecursiveItemCount,Status,OfficialRating"),
                URLQueryItem(name: "enableUserData", value: "true"),
                URLQueryItem(name: "SortBy", value: sortBy),
                URLQueryItem(name: "SortOrder", value: sortOrder),
                URLQueryItem(name: "AudioLanguages", value: values)
            ]
        )
        let response = try await api.decode(JellyfinAPI.ItemsResponse.self, from: request, decoder: decoder)
        return response.items.compactMap { mapItem($0) }
    }

    /// Whether this server supports the `?AudioLanguages=` filter, probed once
    /// via `/Items/Filters2` and memoized. The facet's presence in the response
    /// is the signal — it shipped in the same PR as the query param, so the two
    /// are coupled. A probe that throws returns `false` *without* caching, so a
    /// later attempt retries (a transient failure shouldn't permanently disable
    /// the fast path).
    private func supportsServerAudioFilter() async -> Bool {
        if let cached = cachedAudioFilterSupport { return cached }
        let request = makeRequest(
            path: "/Items/Filters2",
            queryItems: [
                URLQueryItem(name: "UserId", value: userID),
                URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series")
            ]
        )
        guard let filters = try? await api.decode(
            JellyfinAPI.QueryFiltersResponse.self, from: request, decoder: decoder
        ) else {
            return false   // transient — don't memoize, let the next attempt retry
        }
        let supported = filters.audioLanguages != nil
        cachedAudioFilterSupport = supported
        return supported
    }

    /// Mark watched on the server: `POST /Users/{userId}/PlayedItems/{itemId}`
    /// flips Jellyfin's `UserData.Played` so the state syncs across clients.
    /// Best-effort — a failure is swallowed so it never disrupts teardown.
    public func markWatched(_ id: MediaID) async {
        guard id.source == self.id else { return }
        var request = makeRequest(path: "/Users/\(userID)/PlayedItems/\(id.rawValue)")
        request.httpMethod = "POST"
        _ = try? await api.data(for: request)
    }

    /// Mark unwatched: `DELETE /Users/{userId}/PlayedItems/{itemId}`.
    public func markUnwatched(_ id: MediaID) async {
        guard id.source == self.id else { return }
        var request = makeRequest(path: "/Users/\(userID)/PlayedItems/\(id.rawValue)")
        request.httpMethod = "DELETE"
        _ = try? await api.data(for: request)
    }

    /// Report the playhead to Jellyfin via `POST /Sessions/Playing/Progress`,
    /// so resume progress (`UserData.PlaybackPositionTicks`) syncs across
    /// clients and devices. `PositionTicks` are 100-ns units (seconds × 10⁷).
    /// Best-effort — a failure is swallowed so it never disrupts teardown.
    public func recordProgress(_ id: MediaID, position: Duration, duration: Duration?, paused: Bool) async {
        guard id.source == self.id else { return }
        let ticks = Int64((Self.seconds(position) * 10_000_000).rounded())
        let body: [String: Any] = [
            "ItemId": id.rawValue,
            "PositionTicks": ticks,
            "IsPaused": paused
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = makeRequest(path: "/Sessions/Playing/Progress")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        _ = try? await api.data(for: request)
    }

    /// Jellyfin's own Resume list (`GET /Users/{id}/Items/Resume`) as resume
    /// points — the server's "Continue Watching", so a fresh device surfaces
    /// in-progress titles/episodes without local history. `PlaybackPositionTicks`
    /// is the playhead; `LastPlayedDate` the merge timestamp. Best-effort.
    public func serverResumePoints() async -> [ResumePoint] {
        let request = makeRequest(
            path: "/Users/\(userID)/Items/Resume",
            queryItems: [
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "MediaTypes", value: "Video"),
                URLQueryItem(name: "IncludeItemTypes", value: "Movie,Episode"),
                URLQueryItem(name: "enableUserData", value: "true"),
                URLQueryItem(name: "Limit", value: "60")
            ]
        )
        guard let response = try? await api.decode(
            JellyfinAPI.ItemsResponse.self, from: request, decoder: decoder
        ) else { return [] }
        return response.items.compactMap { dto in
            guard let ticks = dto.userData?.playbackPositionTicks, ticks > 0 else { return nil }
            let updatedAt = JellyfinAPI.BaseItemDto.parseDate(dto.userData?.lastPlayedDate) ?? Date()
            return ResumePoint(
                mediaID: MediaID(source: id, rawValue: dto.id),
                position: .seconds(Double(ticks) / 10_000_000),
                updatedAt: updatedAt
            )
        }
    }

    /// Jellyfin has a per-user favorite (`UserData.IsFavorite`).
    public nonisolated var supportsFavorites: Bool { true }

    /// Toggle favorite on the server: `POST` (favorite) / `DELETE` (unfavorite)
    /// `/Users/{userId}/FavoriteItems/{itemId}`, flipping `UserData.IsFavorite`
    /// so it syncs across clients. Best-effort — failures are swallowed.
    public func setFavorite(_ id: MediaID, to favorite: Bool) async {
        guard id.source == self.id else { return }
        var request = makeRequest(path: "/Users/\(userID)/FavoriteItems/\(id.rawValue)")
        request.httpMethod = favorite ? "POST" : "DELETE"
        _ = try? await api.data(for: request)
    }

    // MARK: - Identify (#identify)

    /// Ask the server's metadata providers for matches for a mis- or
    /// unidentified item — the same lookup the web "Identify" dialog runs.
    /// `POST /Items/RemoteSearch/Movie` (or `/Series`). Unlike most calls here
    /// this **throws**: the UI needs to distinguish "no matches" from "the
    /// request failed" (e.g. a non-admin token gets 403). `name`/`year` are the
    /// cleaned query (caller runs `TitleInference` over the raw title first).
    public func identifyCandidates(
        for id: MediaID,
        kind: MediaItem.Kind,
        name: String,
        year: Int?
    ) async throws -> [JellyfinAPI.RemoteSearchResult] {
        let path = kind == .show ? "/Items/RemoteSearch/Series" : "/Items/RemoteSearch/Movie"
        var request = makeRequest(path: path)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let query = JellyfinAPI.RemoteSearchQuery(
            itemId: id.rawValue,
            searchInfo: .init(name: name, year: year)
        )
        request.httpBody = try JSONEncoder().encode(query)
        return try await api.decode([JellyfinAPI.RemoteSearchResult].self, from: request, decoder: decoder)
    }

    /// Apply a chosen candidate: `POST /Items/RemoteSearch/Apply/{itemId}` sends
    /// the result back, and the server pulls full metadata + artwork from its
    /// `providerIds` and refreshes the item — the title is now matched server-side
    /// for every client. Throws so the UI can report a failure.
    public func applyIdentification(
        _ id: MediaID,
        result: JellyfinAPI.RemoteSearchResult,
        replaceImages: Bool = true
    ) async throws {
        var request = makeRequest(
            path: "/Items/RemoteSearch/Apply/\(id.rawValue)",
            queryItems: [URLQueryItem(name: "replaceAllImages", value: replaceImages ? "true" : "false")]
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(result)
        let (_, response) = try await api.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw APIClientError.unexpectedStatus(response.statusCode)
        }
    }

    /// Skip segments via Jellyfin's MediaSegments API (10.10+). Returns `[]` on
    /// older servers / no data — skip controls then stay hidden.
    public func segments(for id: MediaID) async -> [PlaybackSegment] {
        guard id.source == self.id else { return [] }
        let request = makeRequest(
            path: "/MediaSegments/\(id.rawValue)",
            queryItems: [
                URLQueryItem(name: "includeSegmentTypes", value: "Intro"),
                URLQueryItem(name: "includeSegmentTypes", value: "Outro"),
                URLQueryItem(name: "includeSegmentTypes", value: "Recap"),
                URLQueryItem(name: "includeSegmentTypes", value: "Preview"),
                URLQueryItem(name: "includeSegmentTypes", value: "Commercial")
            ]
        )
        guard let response = try? await api.decode(
            JellyfinAPI.MediaSegmentsResponse.self, from: request, decoder: decoder
        ) else { return [] }
        return response.items.compactMap(\.segment)
    }

    /// Similar titles via `GET /Items/{id}/Similar` — Jellyfin's own
    /// recommendation. Requests the same fields the grid needs (poster art,
    /// play state). Best-effort: `[]` on failure.
    public func related(to id: MediaID) async -> [MediaItem] {
        guard id.source == self.id else { return [] }
        let request = makeRequest(
            path: "/Items/\(id.rawValue)/Similar",
            queryItems: [
                URLQueryItem(name: "userId", value: userID),
                URLQueryItem(name: "limit", value: "24"),
                URLQueryItem(name: "Fields", value: "Overview,Genres,ProviderIds,ProductionYear"),
                URLQueryItem(name: "enableUserData", value: "true")
            ]
        )
        guard let response = try? await api.decode(
            JellyfinAPI.ItemsResponse.self, from: request, decoder: decoder
        ) else { return [] }
        return response.items.compactMap { mapItem($0) }
    }

    // MARK: - Library facets (#273)

    public nonisolated var supportsCollections: Bool { true }
    public nonisolated var supportsPeople: Bool { true }

    /// Collections are Jellyfin **BoxSets**. Mapped directly to
    /// `MediaCollection` — `mapItem` would silently drop them (kind guard).
    public func collections() async -> [MediaCollection] {
        let request = makeRequest(
            path: "/Users/\(userID)/Items",
            queryItems: [
                URLQueryItem(name: "IncludeItemTypes", value: "BoxSet"),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "Fields", value: "ChildCount"),
                URLQueryItem(name: "SortBy", value: "SortName"),
                URLQueryItem(name: "SortOrder", value: "Ascending"),
            ]
        )
        guard let response = try? await api.decode(
            JellyfinAPI.ItemsResponse.self, from: request, decoder: decoder
        ) else { return [] }
        return response.items.compactMap { dto in
            guard let name = dto.name else { return nil }
            return MediaCollection(
                id: .init(source: id, rawValue: dto.id),
                title: name,
                childCount: dto.childCount,
                artwork: ArtworkSource(
                    provider: .jellyfin, base: baseURL, token: accessToken,
                    posterPath: "/Items/\(dto.id)/Images/Primary", posterTag: dto.imageTags?["Primary"],
                    backdropPath: "/Items/\(dto.id)/Images/Backdrop", backdropTag: dto.backdropImageTags?.first
                )
            )
        }
    }

    /// BoxSet members come back from the same children endpoint as seasons.
    public func items(inCollection collectionID: MediaID) async -> [MediaItem] {
        guard collectionID.source == self.id else { return [] }
        return (try? await children(of: collectionID)) ?? []
    }

    /// People from `/Persons`, filtered server-side by type.
    public func people(_ kind: PersonKind) async -> [MediaPerson] {
        let request = makeRequest(
            path: "/Persons",
            queryItems: [
                URLQueryItem(name: "userId", value: userID),
                URLQueryItem(name: "personTypes", value: kind == .actor ? "Actor" : "Director"),
                URLQueryItem(name: "Limit", value: "1000"),
                URLQueryItem(name: "SortBy", value: "SortName"),
                URLQueryItem(name: "SortOrder", value: "Ascending"),
            ]
        )
        guard let response = try? await api.decode(
            JellyfinAPI.ItemsResponse.self, from: request, decoder: decoder
        ) else { return [] }
        return response.items.compactMap { dto in
            guard let name = dto.name else { return nil }
            return MediaPerson(
                id: .init(source: id, rawValue: dto.id),
                kind: kind,
                name: name,
                artwork: dto.imageTags?["Primary"].map { tag in
                    ArtworkSource(provider: .jellyfin, base: baseURL, token: accessToken,
                                  posterPath: "/Items/\(dto.id)/Images/Primary", posterTag: tag,
                                  backdropPath: nil)
                }
            )
        }
    }

    /// Every movie / series featuring the person (`PersonIds` filter).
    public func items(withPerson person: MediaPerson) async -> [MediaItem] {
        guard person.id.source == self.id else { return [] }
        let request = makeRequest(
            path: "/Users/\(userID)/Items",
            queryItems: [
                URLQueryItem(name: "PersonIds", value: person.id.rawValue),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"),
                URLQueryItem(name: "Fields", value: "Overview,MediaSources,MediaStreams,ProductionYear,ProviderIds,Genres,DateCreated,PremiereDate,EndDate,CommunityRating,ChildCount,RecursiveItemCount,Status,OfficialRating,People"),
                URLQueryItem(name: "enableUserData", value: "true"),
                URLQueryItem(name: "SortBy", value: "SortName"),
                URLQueryItem(name: "SortOrder", value: "Ascending"),
            ]
        )
        guard let response = try? await api.decode(
            JellyfinAPI.ItemsResponse.self, from: request, decoder: decoder
        ) else { return [] }
        return response.items.compactMap { mapItem($0) }
    }

    public func resolvePlayback(_ request: PlaybackRequest) async throws -> ResolvedPlayback {
        let offsetSeconds = request.startTime.map(Self.seconds(_:)).map { max(0, $0) } ?? 0
        switch request.mode {
        case .directPlay:
            // Hybrid (#68): the static direct-play stream ships the container
            // as-is and ignores AudioStreamIndex, so an EXPLICIT track pick
            // reroutes to the transcoder, which muxes the chosen streams.
            // Default selections keep the cheaper direct play.
            if request.hasExplicitTrackSelection {
                return try await resolveTranscode(request, offsetSeconds: offsetSeconds)
            }
            guard let url = request.directPlayURL else { throw PlaybackResolveError.noPlayableStream }
            return ResolvedPlayback(url: url, isServerTranscode: false, baseOffsetSeconds: 0, decision: .directPlay)

        case .transcode:
            return try await resolveTranscode(request, offsetSeconds: offsetSeconds)
        }
    }

    /// Resolve a transcode. **From zero** uses the hand-built HLS URL directly —
    /// it's proven, has no extra round-trip, and (unlike the PlaybackInfo
    /// TranscodingUrl) doesn't loop the first segments. **Resume** (offset > 0)
    /// must negotiate via `PlaybackInfo`: a hand-built `master.m3u8?startTimeTicks`
    /// is rejected by the server with `NSURLErrorDomain -1008`, so we ask the
    /// server for the exact authorized `TranscodingUrl` (offset + `PlaySessionId`
    /// baked in). PlaybackInfo failures fall back to the hand-built URL.
    private func resolveTranscode(_ request: PlaybackRequest, offsetSeconds: Double) async throws -> ResolvedPlayback {
        if offsetSeconds > 0,
           let resolved = try? await playbackInfoTranscode(
               itemID: request.itemID.rawValue,
               offsetSeconds: offsetSeconds,
               audioStreamID: request.audioStreamID,
               subtitleStreamID: request.subtitleStreamID
           ) {
            return resolved
        }
        // From zero (or PlaybackInfo unavailable): legacy hand-built HLS.
        guard let url = transcodeURL(
            itemID: request.itemID.rawValue,
            audioStreamID: request.audioStreamID,
            subtitleStreamID: request.subtitleStreamID,
            offsetSeconds: offsetSeconds > 0 ? offsetSeconds : nil
        ) else {
            throw PlaybackResolveError.noPlayableStream
        }
        return ResolvedPlayback(url: url, isServerTranscode: true, baseOffsetSeconds: offsetSeconds, decision: .transcode)
    }

    /// `POST /Items/{id}/PlaybackInfo` → use the server's authorized URL. Returns
    /// `nil`-free by throwing when the server offers no usable stream, so the
    /// caller can fall back.
    private func playbackInfoTranscode(
        itemID: String,
        offsetSeconds: Double,
        audioStreamID: String?,
        subtitleStreamID: String?
    ) async throws -> ResolvedPlayback {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/Items/\(itemID)/PlaybackInfo"),
            resolvingAgainstBaseURL: false
        )!
        var query = [
            URLQueryItem(name: "UserId", value: userID),
            URLQueryItem(name: "api_key", value: accessToken),
            URLQueryItem(name: "MaxStreamingBitrate", value: "120000000"),
            URLQueryItem(name: "MediaSourceId", value: itemID)
        ]
        if offsetSeconds > 0 {
            query.append(URLQueryItem(name: "StartTimeTicks", value: String(Int64(offsetSeconds.rounded()) * 10_000_000)))
        }
        if let audioStreamID {
            query.append(URLQueryItem(name: "AudioStreamIndex", value: audioStreamID))
        }
        if let subtitleStreamID, subtitleStreamID != "0" {
            query.append(URLQueryItem(name: "SubtitleStreamIndex", value: subtitleStreamID))
        }
        components.queryItems = query

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in configuration.commonHeaders(token: accessToken) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        // Device profile: direct-play mp4/m4v/mov, otherwise transcode to HLS
        // (h264/aac) so mkv etc. come back with a TranscodingUrl.
        let deviceProfile: [String: Any] = [
            "MaxStreamingBitrate": 120_000_000,
            "DirectPlayProfiles": [
                ["Container": "mp4,m4v,mov", "Type": "Video",
                 "VideoCodec": "h264,hevc", "AudioCodec": "aac,mp3,ac3,eac3"]
            ],
            "TranscodingProfiles": [
                ["Container": "ts", "Type": "Video", "Protocol": "hls",
                 "VideoCodec": "h264", "AudioCodec": "aac,mp3",
                 "Context": "Streaming", "MinSegments": 1]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: ["DeviceProfile": deviceProfile])

        let info = try await api.decode(JellyfinAPI.PlaybackInfoResponse.self, from: request, decoder: decoder)
        guard let media = info.mediaSources.first else { throw PlaybackResolveError.noPlayableStream }

        if let transcoding = media.transcodingURL, let url = absolutePlaybackURL(transcoding) {
            return ResolvedPlayback(
                url: url, isServerTranscode: true, baseOffsetSeconds: offsetSeconds,
                transcodeSessionID: info.playSessionID, decision: .transcode
            )
        }
        if let direct = media.directStreamURL, let url = absolutePlaybackURL(direct) {
            return ResolvedPlayback(
                url: url, isServerTranscode: false, baseOffsetSeconds: 0,
                clientSeekSeconds: offsetSeconds > 0 ? offsetSeconds : nil, decision: .directPlay
            )
        }
        throw PlaybackResolveError.noPlayableStream
    }

    /// Resolve a server-relative playback URL (`TranscodingUrl` / `DirectStreamUrl`)
    /// against the connected base URL, preserving any reverse-proxy base path and
    /// ensuring the `api_key` is present.
    private func absolutePlaybackURL(_ relative: String) -> URL? {
        guard var components = URLComponents(string: relative) else { return nil }
        guard let base = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = base.scheme
        components.host = base.host
        components.port = base.port
        let basePath = base.path
        if !basePath.isEmpty, basePath != "/", !components.path.hasPrefix(basePath) {
            components.path = basePath + components.path
        }
        var items = components.queryItems ?? []
        if !items.contains(where: { $0.name.lowercased() == "api_key" }) {
            items.append(URLQueryItem(name: "api_key", value: accessToken))
        }
        components.queryItems = items
        return components.url
    }

    // MARK: - Downloads

    /// Jellyfin supports downloads. Synchronous flag so Detail's Download
    /// button visibility is decided at view-render time without an actor hop
    /// (mirrors `PlexMediaSource`).
    public nonisolated var supportsDownloads: Bool { true }

    /// Build a download URL the `DownloadManager`'s background `URLSession` can
    /// pull in one GET.
    ///
    /// - `.original` → the canonical `/Items/{id}/Download` endpoint: the raw
    ///   source file, no transcode (single GET, movable file). Same thing the
    ///   Jellyfin web client's Download button uses.
    /// - any capped / convert quality → a **progressive MP4** transcode via
    ///   `/Videos/{id}/stream.mp4?static=false`, with the bitrate / height caps
    ///   applied, so the file is smaller and AVPlayer-friendly.
    public func downloadURL(for item: MediaItem, quality: PlaybackQuality) async throws -> URL? {
        guard item.id.source == self.id else { return nil }
        let itemID = item.id.rawValue

        if quality == .original {
            var components = URLComponents(
                url: baseURL.appendingPathComponent("/Items/\(itemID)/Download"),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [URLQueryItem(name: "api_key", value: accessToken)]
            return components?.url
        }

        var components = URLComponents(
            url: baseURL.appendingPathComponent("/Videos/\(itemID)/stream.mp4"),
            resolvingAgainstBaseURL: false
        )
        var queryItems = [
            URLQueryItem(name: "static", value: "false"),
            URLQueryItem(name: "container", value: "mp4"),
            URLQueryItem(name: "VideoCodec", value: "h264"),
            URLQueryItem(name: "AudioCodec", value: "aac"),
            URLQueryItem(name: "MediaSourceId", value: itemID),
            URLQueryItem(name: "api_key", value: accessToken),
            URLQueryItem(name: "DeviceId", value: configuration.deviceID),
            // Fresh session each download so a stuck job can't poison the next.
            URLQueryItem(name: "PlaySessionId", value: UUID().uuidString)
        ]
        if let kbps = quality.maxVideoBitrateKbps {
            queryItems.append(URLQueryItem(name: "VideoBitrate", value: String(kbps * 1000)))
        }
        if let maxHeight = Self.maxHeight(for: quality) {
            queryItems.append(URLQueryItem(name: "MaxHeight", value: String(maxHeight)))
        }
        components?.queryItems = queryItems
        return components?.url
    }

    /// Pixel height from a `PlaybackQuality.videoResolution` like `"1920x1080"`.
    private static func maxHeight(for quality: PlaybackQuality) -> Int? {
        guard let resolution = quality.videoResolution else { return nil }
        return resolution.split(separator: "x").last.flatMap { Int($0) }
    }

    // MARK: - Stream URLs

    /// Containers AVPlayer opens natively → direct-play the static file;
    /// anything else → HLS transcode. Mirrors `PlexMediaSource`.
    private static let directPlayContainers: Set<String> = ["mp4", "m4v", "mov"]

    private func streamURL(for dto: JellyfinAPI.BaseItemDto) -> URL? {
        guard dto.kind?.isContainer == false else { return nil } // shows/seasons aren't playable
        guard dto.mediaSourceID != nil || dto.container != nil else { return nil }

        if let container = dto.container?.lowercased(), Self.directPlayContainers.contains(container) {
            return directStreamURL(itemID: dto.id, mediaSourceID: dto.mediaSourceID)
        }
        return transcodeURL(itemID: dto.id, audioStreamID: nil, subtitleStreamID: nil, offsetSeconds: nil)
    }

    private func directStreamURL(itemID: String, mediaSourceID: String?) -> URL? {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/Videos/\(itemID)/stream"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "mediaSourceId", value: mediaSourceID ?? itemID),
            URLQueryItem(name: "api_key", value: accessToken)
        ]
        return components?.url
    }

    /// Build a fresh HLS transcode URL. A new `PlaySessionId` every call so a
    /// reaped server-side transcode can't resurface (same philosophy as the
    /// Plex `session` regeneration that fixed -1008).
    private func transcodeURL(
        itemID: String,
        audioStreamID: String?,
        subtitleStreamID: String?,
        offsetSeconds: Double?
    ) -> URL? {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/Videos/\(itemID)/master.m3u8"),
            resolvingAgainstBaseURL: false
        )
        var queryItems = [
            URLQueryItem(name: "MediaSourceId", value: itemID),
            URLQueryItem(name: "api_key", value: accessToken),
            URLQueryItem(name: "DeviceId", value: configuration.deviceID),
            URLQueryItem(name: "PlaySessionId", value: UUID().uuidString),
            URLQueryItem(name: "VideoCodec", value: "h264"),
            URLQueryItem(name: "AudioCodec", value: "aac,mp3"),
            URLQueryItem(name: "TranscodingProtocol", value: "hls"),
            URLQueryItem(name: "TranscodingContainer", value: "ts")
        ]
        if let audioStreamID {
            queryItems.append(URLQueryItem(name: "AudioStreamIndex", value: audioStreamID))
        }
        if let subtitleStreamID {
            // Burn subtitles into the transcode so any format renders; "0"/off
            // disables via -1.
            queryItems.append(URLQueryItem(name: "SubtitleStreamIndex", value: subtitleStreamID == "0" ? "-1" : subtitleStreamID))
            queryItems.append(URLQueryItem(name: "SubtitleMethod", value: "Encode"))
        }
        if let offsetSeconds, offsetSeconds > 0 {
            queryItems.append(URLQueryItem(name: "startTimeTicks", value: String(Int64(offsetSeconds.rounded()) * 10_000_000)))
        }
        components?.queryItems = queryItems
        return components?.url
    }

    // MARK: - Images

    // MARK: - Mapping

    private func mapItem(_ dto: JellyfinAPI.BaseItemDto) -> MediaItem? {
        guard let kind = dto.kind else { return nil }
        let url = streamURL(for: dto)
        // Tracks are surfaced on EVERY playable — direct play included (#68).
        // They used to be hidden off the transcode path because `static=true`
        // ignores stream indexes; resolvePlayback now reroutes an explicit
        // pick to the transcoder instead, so the pickers actually work.
        let audioTracks = dto.audioTracks
        let subtitleTracks = dto.subtitleTracks
        // Artwork as a tier-aware source; the baked poster/backdrop below are its
        // default tiers. A nil tag → nil URL, so a title without art stays blank.
        let artwork = ArtworkSource(
            provider: .jellyfin, base: baseURL, token: accessToken,
            posterPath: "/Items/\(dto.id)/Images/Primary", posterTag: dto.imageTags?["Primary"],
            backdropPath: "/Items/\(dto.id)/Images/Backdrop", backdropTag: dto.backdropImageTags?.first,
            // clearLogo — present only when ImageTags carries a Logo hash; the
            // logoURL builder guards on the tag, so no Logo → no URL.
            logoPath: "/Items/\(dto.id)/Images/Logo", logoTag: dto.imageTags?["Logo"]
        )
        let cast = mapCast(dto.people)
        return MediaItem(
            id: .init(source: id, rawValue: dto.id),
            title: dto.name ?? "Untitled",
            kind: kind,
            year: dto.productionYear,
            runtime: dto.runTimeTicks.map { .seconds(Double($0) / 10_000_000.0) },
            summary: dto.overview,
            posterURL: artwork.posterURL(.thumbnail),
            backdropURL: artwork.backdropURL(.backdrop),
            streamURL: url,
            audioTracks: audioTracks,
            selectedAudioTrackID: audioTracks.first(where: \.isSelected)?.id,
            subtitleTracks: subtitleTracks,
            selectedSubtitleTrackID: subtitleTracks.first(where: \.isSelected)?.id,
            mediaInfo: dto.sourceMediaInfo,
            seriesTitle: dto.seriesName,
            // Season: its own IndexNumber. Episode: season = ParentIndexNumber,
            // episode = IndexNumber.
            seasonNumber: kind == .season ? dto.indexNumber : dto.parentIndexNumber,
            episodeNumber: kind == .episode ? dto.indexNumber : nil,
            guids: dto.guids,
            isWatched: dto.isWatched,
            isFavorite: dto.isFavorite,
            parentID: dto.parentId.map { MediaID(source: id, rawValue: $0) },
            genres: dto.genreList,
            cast: cast,
            communityRating: dto.communityRating,
            contentRating: dto.contentRating,
            releaseDate: dto.releaseDate,
            dateAdded: dto.dateAdded,
            seasonCount: dto.childCount,
            episodeCount: dto.recursiveItemCount,
            endYear: dto.endYear,
            isContinuing: dto.status.map { $0 == "Continuing" },
            unwatchedEpisodeCount: dto.userData?.unplayedItemCount,
            artwork: artwork
        )
    }

    // MARK: - Cast & Crew

    /// Map Jellyfin `People` to `CastMember`s — actors first (with their
    /// character), then key crew (director / writer). Headshots come from the
    /// person's Primary image, sized like a poster. Capped for the rail.
    private func mapCast(_ people: [JellyfinAPI.BaseItemDto.BaseItemPerson]?) -> [CastMember] {
        guard let people else { return [] }
        let actors = people.filter { $0.type == "Actor" }
        let crew = people.filter { $0.type == "Director" || $0.type == "Writer" }
        return (actors + crew).prefix(20).enumerated().compactMap { index, person in
            guard let name = person.name?.nonEmptyTrimmed else { return nil }
            let photoURL: URL? = person.id?.nonEmptyTrimmed.flatMap { personID in
                ArtworkSource(provider: .jellyfin, base: baseURL, token: accessToken,
                              posterPath: "/Items/\(personID)/Images/Primary",
                              posterTag: person.primaryImageTag,
                              backdropPath: nil).posterURL(.thumbnail)
            }
            let role = person.role?.nonEmptyTrimmed
                ?? (person.type == "Actor" ? nil : person.type?.nonEmptyTrimmed)
            return CastMember(id: person.id ?? "\(index)-\(name)", name: name,
                              role: role, photoURL: photoURL, personID: person.id)
        }
    }

    // MARK: - Helpers

    private func makeRequest(path: String, queryItems: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        if !queryItems.isEmpty { components.queryItems = queryItems }
        var request = URLRequest(url: components.url!)
        for (key, value) in configuration.commonHeaders(token: accessToken) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    private static func jellyfinSort(_ sort: LibrarySort) -> (sortBy: String, order: String) {
        switch sort {
        case .titleAZ:       return ("SortName", "Ascending")
        case .titleZA:       return ("SortName", "Descending")
        case .yearNewest:    return ("ProductionYear", "Descending")
        case .yearOldest:    return ("ProductionYear", "Ascending")
        case .recentlyAdded: return ("DateCreated", "Descending")
        case .ratingHighest: return ("CommunityRating", "Descending")
        case .random:        return ("Random", "Ascending")
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
