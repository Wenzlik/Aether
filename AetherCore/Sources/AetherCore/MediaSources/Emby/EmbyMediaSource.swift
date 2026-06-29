import Foundation

/// An Emby server wired up as an Aether `MediaSource`.
///
/// The Emby API surface is nearly identical to Jellyfin — both share the same
/// upstream codebase. The key difference is the absence of a MediaSegments
/// endpoint for skip-intro/outro (Emby exposes this via a plugin, not a
/// public REST endpoint), so `segments(for:)` always returns `[]`.
public actor EmbyMediaSource: MediaSource {
    public let id: MediaSourceID
    public let displayName: String

    private let baseURL: URL
    private let accessToken: String
    private let userID: String
    private let configuration: EmbyConfiguration
    private let api: any APIClient
    private let decoder: JSONDecoder

    public init(
        serverID: String,
        displayName: String,
        baseURL: URL,
        accessToken: String,
        userID: String,
        configuration: EmbyConfiguration,
        api: any APIClient
    ) {
        self.id = .emby(serverID: serverID)
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
        let response = try await api.decode(EmbyAPI.ItemsResponse.self, from: request, decoder: decoder)
        return response.items.compactMap { dto in
            let kind: MediaItem.Kind
            switch dto.collectionType {
            case "movies":  kind = .movie
            case "tvshows": kind = .show
            default:        return nil
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
        let (sortBy, sortOrder) = Self.embySort(sort)
        var queryItems = [
            URLQueryItem(name: "ParentId", value: libraryID.rawValue),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"),
            URLQueryItem(name: "Fields", value: "Overview,MediaSources,MediaStreams,ProductionYear,ProviderIds,Genres,DateCreated,PremiereDate,EndDate,CommunityRating,ChildCount,RecursiveItemCount,Status,OfficialRating,People"),
            URLQueryItem(name: "enableUserData", value: "true"),
            URLQueryItem(name: "SortBy", value: sortBy),
            URLQueryItem(name: "SortOrder", value: sortOrder)
        ]
        if let offset { queryItems.append(URLQueryItem(name: "StartIndex", value: String(offset))) }
        if let limit  { queryItems.append(URLQueryItem(name: "Limit",      value: String(limit))) }

        let request = makeRequest(path: "/Users/\(userID)/Items", queryItems: queryItems)
        let response = try await api.decode(EmbyAPI.ItemsResponse.self, from: request, decoder: decoder)
        return response.items.compactMap { mapItem($0) }
    }

    public func children(of id: MediaID) async throws -> [MediaItem] {
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
        let response = try await api.decode(EmbyAPI.ItemsResponse.self, from: request, decoder: decoder)
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
        let dto = try await api.decode(EmbyAPI.BaseItemDto.self, from: request, decoder: decoder)
        return mapItem(dto)
    }

    public func markWatched(_ id: MediaID) async {
        guard id.source == self.id else { return }
        var request = makeRequest(path: "/Users/\(userID)/PlayedItems/\(id.rawValue)")
        request.httpMethod = "POST"
        _ = try? await api.data(for: request)
    }

    public func markUnwatched(_ id: MediaID) async {
        guard id.source == self.id else { return }
        var request = makeRequest(path: "/Users/\(userID)/PlayedItems/\(id.rawValue)")
        request.httpMethod = "DELETE"
        _ = try? await api.data(for: request)
    }

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
            EmbyAPI.ItemsResponse.self, from: request, decoder: decoder
        ) else { return [] }
        return response.items.compactMap { dto in
            guard let ticks = dto.userData?.playbackPositionTicks, ticks > 0 else { return nil }
            let updatedAt = EmbyAPI.BaseItemDto.parseDate(dto.userData?.lastPlayedDate) ?? Date()
            return ResumePoint(
                mediaID: MediaID(source: id, rawValue: dto.id),
                position: .seconds(Double(ticks) / 10_000_000),
                updatedAt: updatedAt
            )
        }
    }

    public nonisolated var supportsFavorites: Bool { true }

    public func setFavorite(_ id: MediaID, to favorite: Bool) async {
        guard id.source == self.id else { return }
        var request = makeRequest(path: "/Users/\(userID)/FavoriteItems/\(id.rawValue)")
        request.httpMethod = favorite ? "POST" : "DELETE"
        _ = try? await api.data(for: request)
    }

    /// Emby does not expose a public skip-segments REST endpoint — returns `[]`
    /// so skip controls stay hidden (same behaviour as Plex, which also lacks it).
    public func segments(for id: MediaID) async -> [PlaybackSegment] { [] }

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
            EmbyAPI.ItemsResponse.self, from: request, decoder: decoder
        ) else { return [] }
        return response.items.compactMap { mapItem($0) }
    }

    // MARK: - Library facets

    public nonisolated var supportsCollections: Bool { true }
    public nonisolated var supportsPeople: Bool { true }

    public func collections() async -> [MediaCollection] {
        let request = makeRequest(
            path: "/Users/\(userID)/Items",
            queryItems: [
                URLQueryItem(name: "IncludeItemTypes", value: "BoxSet"),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "Fields", value: "ChildCount"),
                URLQueryItem(name: "SortBy", value: "SortName"),
                URLQueryItem(name: "SortOrder", value: "Ascending")
            ]
        )
        guard let response = try? await api.decode(
            EmbyAPI.ItemsResponse.self, from: request, decoder: decoder
        ) else { return [] }
        return response.items.compactMap { dto in
            guard let name = dto.name else { return nil }
            return MediaCollection(
                id: .init(source: id, rawValue: dto.id),
                title: name,
                childCount: dto.childCount,
                artwork: ArtworkSource(
                    provider: .emby, base: baseURL, token: accessToken,
                    posterPath: "/Items/\(dto.id)/Images/Primary", posterTag: dto.imageTags?["Primary"],
                    backdropPath: "/Items/\(dto.id)/Images/Backdrop", backdropTag: dto.backdropImageTags?.first
                )
            )
        }
    }

    public func items(inCollection collectionID: MediaID) async -> [MediaItem] {
        guard collectionID.source == self.id else { return [] }
        return (try? await children(of: collectionID)) ?? []
    }

    public func people(_ kind: PersonKind) async -> [MediaPerson] {
        let request = makeRequest(
            path: "/Persons",
            queryItems: [
                URLQueryItem(name: "userId", value: userID),
                URLQueryItem(name: "personTypes", value: kind == .actor ? "Actor" : "Director"),
                URLQueryItem(name: "Limit", value: "1000"),
                URLQueryItem(name: "SortBy", value: "SortName"),
                URLQueryItem(name: "SortOrder", value: "Ascending")
            ]
        )
        guard let response = try? await api.decode(
            EmbyAPI.ItemsResponse.self, from: request, decoder: decoder
        ) else { return [] }
        return response.items.compactMap { dto in
            guard let name = dto.name else { return nil }
            return MediaPerson(
                id: .init(source: id, rawValue: dto.id),
                kind: kind,
                name: name,
                artwork: dto.imageTags?["Primary"].map { tag in
                    ArtworkSource(provider: .emby, base: baseURL, token: accessToken,
                                  posterPath: "/Items/\(dto.id)/Images/Primary", posterTag: tag,
                                  backdropPath: nil)
                }
            )
        }
    }

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
                URLQueryItem(name: "SortOrder", value: "Ascending")
            ]
        )
        guard let response = try? await api.decode(
            EmbyAPI.ItemsResponse.self, from: request, decoder: decoder
        ) else { return [] }
        return response.items.compactMap { mapItem($0) }
    }

    public func resolvePlayback(_ request: PlaybackRequest) async throws -> ResolvedPlayback {
        switch request.mode {
        case .directPlay:
            if request.hasExplicitTrackSelection {
                let offsetSeconds = request.startTime.map(Self.seconds(_:)).map { max(0, $0) } ?? 0
                if let url = transcodeURL(
                    itemID: request.itemID.rawValue,
                    audioStreamID: request.audioStreamID,
                    subtitleStreamID: request.subtitleStreamID,
                    offsetSeconds: offsetSeconds > 0 ? offsetSeconds : nil
                ) {
                    return ResolvedPlayback(
                        url: url, isServerTranscode: true, baseOffsetSeconds: offsetSeconds,
                        decision: .transcode
                    )
                }
            }
            guard let url = request.directPlayURL else { throw PlaybackResolveError.noPlayableStream }
            return ResolvedPlayback(url: url, isServerTranscode: false, baseOffsetSeconds: 0, decision: .directPlay)

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

    public nonisolated var supportsDownloads: Bool { true }

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

    private static func maxHeight(for quality: PlaybackQuality) -> Int? {
        guard let resolution = quality.videoResolution else { return nil }
        return resolution.split(separator: "x").last.flatMap { Int($0) }
    }

    // MARK: - Stream URLs

    private static let directPlayContainers: Set<String> = ["mp4", "m4v", "mov"]

    private func streamURL(for dto: EmbyAPI.BaseItemDto) -> URL? {
        guard dto.kind?.isContainer == false else { return nil }
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
            queryItems.append(URLQueryItem(name: "SubtitleStreamIndex", value: subtitleStreamID == "0" ? "-1" : subtitleStreamID))
            queryItems.append(URLQueryItem(name: "SubtitleMethod", value: "Encode"))
        }
        if let offsetSeconds, offsetSeconds > 0 {
            queryItems.append(URLQueryItem(name: "startTimeTicks", value: String(Int64(offsetSeconds.rounded()) * 10_000_000)))
        }
        components?.queryItems = queryItems
        return components?.url
    }

    // MARK: - Mapping

    private func mapItem(_ dto: EmbyAPI.BaseItemDto) -> MediaItem? {
        guard let kind = dto.kind else { return nil }
        let url = streamURL(for: dto)
        let audioTracks = dto.audioTracks
        let subtitleTracks = dto.subtitleTracks
        let artwork = ArtworkSource(
            provider: .emby, base: baseURL, token: accessToken,
            posterPath: "/Items/\(dto.id)/Images/Primary", posterTag: dto.imageTags?["Primary"],
            backdropPath: "/Items/\(dto.id)/Images/Backdrop", backdropTag: dto.backdropImageTags?.first,
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
            seasonNumber: kind == .season ? dto.indexNumber : dto.parentIndexNumber,
            episodeNumber: kind == .episode ? dto.indexNumber : nil,
            guids: dto.guids,
            isWatched: dto.isWatched,
            isFavorite: dto.isFavorite,
            lastWatched: EmbyAPI.BaseItemDto.parseDate(dto.userData?.lastPlayedDate),
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

    private func mapCast(_ people: [EmbyAPI.BaseItemDto.BaseItemPerson]?) -> [CastMember] {
        guard let people else { return [] }
        let actors = people.filter { $0.type == "Actor" }
        let crew = people.filter { $0.type == "Director" || $0.type == "Writer" }
        return (actors + crew).prefix(20).enumerated().compactMap { index, person in
            guard let name = person.name?.nonEmptyTrimmed else { return nil }
            let photoURL: URL? = person.id?.nonEmptyTrimmed.flatMap { personID in
                ArtworkSource(provider: .emby, base: baseURL, token: accessToken,
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

    private static func embySort(_ sort: LibrarySort) -> (sortBy: String, order: String) {
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
