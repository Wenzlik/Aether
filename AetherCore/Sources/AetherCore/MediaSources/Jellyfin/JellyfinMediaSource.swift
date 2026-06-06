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
            URLQueryItem(name: "Fields", value: "Overview,MediaSources,MediaStreams,ProductionYear,ProviderIds,Genres,DateCreated,PremiereDate,EndDate,CommunityRating,ChildCount,RecursiveItemCount,Status"),
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
                URLQueryItem(name: "Fields", value: "Overview,MediaSources,MediaStreams,ProductionYear,ProviderIds,Genres,DateCreated,PremiereDate,EndDate,CommunityRating,ChildCount,RecursiveItemCount,Status"),
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
                URLQueryItem(name: "Fields", value: "Overview,MediaSources,MediaStreams,ProductionYear,ProviderIds,Genres,DateCreated,PremiereDate,EndDate,CommunityRating,ChildCount,RecursiveItemCount,Status"),
                URLQueryItem(name: "enableUserData", value: "true")
            ]
        )
        // This endpoint returns a single item, not a wrapped list.
        let dto = try await api.decode(JellyfinAPI.BaseItemDto.self, from: request, decoder: decoder)
        return mapItem(dto)
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

    public func resolvePlayback(_ request: PlaybackRequest) async throws -> ResolvedPlayback {
        switch request.mode {
        case .directPlay:
            guard let url = request.directPlayURL else { throw PlaybackResolveError.noPlayableStream }
            return ResolvedPlayback(url: url, isServerTranscode: false, baseOffsetSeconds: 0)

        case .transcode:
            let offsetSeconds = request.startTime.map(Self.seconds(_:)).map { max(0, $0) } ?? 0
            guard let url = transcodeURL(
                itemID: request.itemID.rawValue,
                audioStreamID: request.audioStreamID,
                subtitleStreamID: request.subtitleStreamID,
                offsetSeconds: offsetSeconds > 0 ? offsetSeconds : nil
            ) else {
                throw PlaybackResolveError.noPlayableStream
            }
            return ResolvedPlayback(url: url, isServerTranscode: true, baseOffsetSeconds: offsetSeconds)
        }
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

    private func imageURL(itemID: String, type: String, tag: String?) -> URL? {
        guard tag != nil else { return nil }
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/Items/\(itemID)/Images/\(type)"),
            resolvingAgainstBaseURL: false
        )
        var queryItems = [URLQueryItem(name: "api_key", value: accessToken)]
        if let tag { queryItems.append(URLQueryItem(name: "tag", value: tag)) }
        components?.queryItems = queryItems
        return components?.url
    }

    // MARK: - Mapping

    private func mapItem(_ dto: JellyfinAPI.BaseItemDto) -> MediaItem? {
        guard let kind = dto.kind else { return nil }
        let url = streamURL(for: dto)
        let isTranscode = url?.pathExtension.lowercased() == "m3u8"
        let audioTracks = isTranscode ? dto.audioTracks : []
        let subtitleTracks = isTranscode ? dto.subtitleTracks : []
        return MediaItem(
            id: .init(source: id, rawValue: dto.id),
            title: dto.name ?? "Untitled",
            kind: kind,
            year: dto.productionYear,
            runtime: dto.runTimeTicks.map { .seconds(Double($0) / 10_000_000.0) },
            summary: dto.overview,
            posterURL: imageURL(itemID: dto.id, type: "Primary", tag: dto.imageTags?["Primary"]),
            backdropURL: imageURL(itemID: dto.id, type: "Backdrop", tag: dto.backdropImageTags?.first),
            streamURL: url,
            audioTracks: audioTracks,
            selectedAudioTrackID: audioTracks.first(where: \.isSelected)?.id,
            subtitleTracks: subtitleTracks,
            selectedSubtitleTrackID: subtitleTracks.first(where: \.isSelected)?.id,
            seriesTitle: dto.seriesName,
            // Season: its own IndexNumber. Episode: season = ParentIndexNumber,
            // episode = IndexNumber.
            seasonNumber: kind == .season ? dto.indexNumber : dto.parentIndexNumber,
            episodeNumber: kind == .episode ? dto.indexNumber : nil,
            guids: dto.guids,
            isWatched: dto.isWatched,
            parentID: dto.parentId.map { MediaID(source: id, rawValue: $0) },
            genres: dto.genreList,
            communityRating: dto.communityRating,
            releaseDate: dto.releaseDate,
            dateAdded: dto.dateAdded,
            seasonCount: dto.childCount,
            episodeCount: dto.recursiveItemCount,
            endYear: dto.endYear,
            isContinuing: dto.status.map { $0 == "Continuing" },
            unwatchedEpisodeCount: dto.userData?.unplayedItemCount
        )
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
