import Testing
import Foundation
@testable import AetherCore

@Suite("Jellyfin — configuration")
struct JellyfinConfigurationTests {
    private static let config = JellyfinConfiguration(
        client: "Aether", version: "0.2.0", deviceName: "Apple TV", deviceID: "dev-1"
    )

    @Test("Authorization header carries Client/Device/DeviceId/Version and the token when present")
    func authHeaderWithToken() {
        let header = Self.config.authorizationHeader(token: "tok-123")
        #expect(header.hasPrefix("MediaBrowser "))
        #expect(header.contains("Client=\"Aether\""))
        #expect(header.contains("Device=\"Apple TV\""))
        #expect(header.contains("DeviceId=\"dev-1\""))
        #expect(header.contains("Version=\"0.2.0\""))
        #expect(header.contains("Token=\"tok-123\""))
    }

    @Test("Authorization header omits the token before sign-in")
    func authHeaderWithoutToken() {
        let header = Self.config.authorizationHeader()
        #expect(header.contains("Client=\"Aether\""))
        #expect(!header.contains("Token="))
    }

    @Test("commonHeaders requests JSON + Authorization")
    func commonHeaders() {
        let headers = Self.config.commonHeaders(token: "t")
        #expect(headers["Accept"] == "application/json")
        #expect(headers["Authorization"]?.contains("Token=\"t\"") == true)
    }
}

@Suite("Jellyfin — decoding")
struct JellyfinDecodingTests {
    private let decoder = JSONDecoder()

    @Test("PublicSystemInfo decodes server name + version")
    func publicInfo() throws {
        let json = #"{"Id":"abc","ServerName":"Den","Version":"10.9.0","ProductName":"Jellyfin Server"}"#
        let info = try decoder.decode(JellyfinAPI.PublicSystemInfo.self, from: Data(json.utf8))
        #expect(info.serverName == "Den")
        #expect(info.version == "10.9.0")
    }

    @Test("QuickConnectResult decodes secret/code/authenticated")
    func quickConnect() throws {
        let json = #"{"Secret":"sec","Code":"123456","Authenticated":false}"#
        let qc = try decoder.decode(JellyfinAPI.QuickConnectResult.self, from: Data(json.utf8))
        #expect(qc.secret == "sec")
        #expect(qc.code == "123456")
        #expect(qc.authenticated == false)
    }

    @Test("AuthenticationResult decodes token + user id")
    func authResult() throws {
        let json = #"{"AccessToken":"abc","ServerId":"s1","User":{"Id":"u1","Name":"me"}}"#
        let auth = try decoder.decode(JellyfinAPI.AuthenticationResult.self, from: Data(json.utf8))
        #expect(auth.accessToken == "abc")
        #expect(auth.user.id == "u1")
    }

    @Test("BaseItemDto maps audio + subtitle MediaStreams to tracks")
    func itemStreams() throws {
        let json = #"""
        {"Id":"42","Name":"Movie","Type":"Movie","RunTimeTicks":60000000000,
         "MediaSources":[{"Id":"42","Container":"mkv","MediaStreams":[
           {"Index":0,"Type":"Video","Codec":"h264"},
           {"Index":1,"Type":"Audio","DisplayTitle":"English 5.1","Language":"eng","Codec":"aac","Channels":6,"IsDefault":true},
           {"Index":2,"Type":"Subtitle","DisplayTitle":"English","Language":"eng","Codec":"srt"}
         ]}]}
        """#
        let dto = try decoder.decode(JellyfinAPI.BaseItemDto.self, from: Data(json.utf8))
        #expect(dto.kind == .movie)
        #expect(dto.container == "mkv")
        #expect(dto.audioTracks.map(\.id) == ["1"])
        #expect(dto.audioTracks.first?.isSelected == true)
        #expect(dto.subtitleTracks.map(\.id) == ["2"])
    }

    @Test("BaseItemDto backfills MediaInfo from MediaStreams + decodes OfficialRating/Size")
    func sourceMediaInfoBackfill() throws {
        let json = #"""
        {"Id":"42","Name":"Movie","Type":"Movie","OfficialRating":"PG-13",
         "MediaSources":[{"Id":"42","Container":"mkv","Size":12884901888,"Bitrate":18000000,"MediaStreams":[
           {"Index":0,"Type":"Video","Codec":"hevc","Width":3840,"Height":2160,"VideoRange":"HDR","VideoRangeType":"DOVI","BitRate":16000000},
           {"Index":1,"Type":"Audio","Codec":"eac3","Channels":6,"IsDefault":true}
         ]}]}
        """#
        let dto = try decoder.decode(JellyfinAPI.BaseItemDto.self, from: Data(json.utf8))
        let info = try #require(dto.sourceMediaInfo)
        #expect(info.videoCodec == "hevc")
        #expect(info.videoResolution == "4K")
        #expect(info.audioCodec == "eac3")
        #expect(info.audioChannels == 6)
        #expect(info.isHDR)
        #expect(info.isDolbyVision)
        #expect(info.container == "mkv")
        #expect(info.fileSizeBytes == 12_884_901_888)
        #expect(info.bitrateKbps == 16_000)        // video stream BitRate (bits/s) → kbps
        #expect(dto.contentRating == "PG-13")
    }

    @Test("BaseItemDto with no MediaSources yields nil MediaInfo, blank rating → nil")
    func sourceMediaInfoAbsent() throws {
        let json = #"{"Id":"7","Name":"Bare","Type":"Movie","OfficialRating":"  "}"#
        let dto = try decoder.decode(JellyfinAPI.BaseItemDto.self, from: Data(json.utf8))
        #expect(dto.sourceMediaInfo == nil)
        #expect(dto.contentRating == nil)
    }

    @Test("BaseItemDto decodes People (cast + crew)")
    func decodesPeople() throws {
        let json = #"""
        {"Id":"42","Name":"First Man","Type":"Movie","People":[
          {"Id":"p1","Name":"Ryan Gosling","Role":"Neil Armstrong","Type":"Actor","PrimaryImageTag":"abc"},
          {"Id":"p2","Name":"Damien Chazelle","Type":"Director"}
        ]}
        """#
        let dto = try decoder.decode(JellyfinAPI.BaseItemDto.self, from: Data(json.utf8))
        let people = try #require(dto.people)
        #expect(people.count == 2)
        #expect(people[0].name == "Ryan Gosling")
        #expect(people[0].role == "Neil Armstrong")
        #expect(people[0].type == "Actor")
        #expect(people[0].primaryImageTag == "abc")
        #expect(people[1].type == "Director")
        #expect(people[1].role == nil)
    }
}

@Suite("Jellyfin — Quick Connect flow")
struct JellyfinAuthFlowTests {
    private static let config = JellyfinConfiguration(
        client: "Aether", version: "0.2.0", deviceName: "Test", deviceID: "dev-1"
    )
    private let base = URL(string: "http://jelly.test:8096")!

    @Test("pollForAuthentication waits for approval then exchanges the secret for a token")
    func pollSucceeds() async throws {
        let api = RecordingAPIClient()
        // Connect: not yet → not yet → authenticated, then AuthenticateWithQuickConnect.
        await api.enqueue(.init(data: Data(#"{"Secret":"sec","Code":"123456","Authenticated":false}"#.utf8), statusCode: 200, headers: [:]))
        await api.enqueue(.init(data: Data(#"{"Secret":"sec","Code":"123456","Authenticated":true}"#.utf8), statusCode: 200, headers: [:]))
        await api.enqueue(.init(data: Data(#"{"AccessToken":"abc","ServerId":"s1","User":{"Id":"u1","Name":"me"}}"#.utf8), statusCode: 200, headers: [:]))

        let client = JellyfinAuthClient(api: api, configuration: Self.config)
        let result = try await client.pollForAuthentication(
            baseURL: base, secret: "sec", interval: .milliseconds(10), timeout: .seconds(5)
        )
        #expect(result.accessToken == "abc")
        #expect(result.user.id == "u1")
    }
}

@Suite("Jellyfin — media source")
struct JellyfinMediaSourceTests {
    private let base = URL(string: "http://jelly.test:8096")!

    private func makeSource(api: any APIClient) -> JellyfinMediaSource {
        JellyfinMediaSource(
            serverID: "http://jelly.test:8096",
            displayName: "Den",
            baseURL: base,
            accessToken: "tok",
            userID: "u1",
            configuration: JellyfinConfiguration(client: "Aether", version: "0.2.0", deviceName: "Test", deviceID: "dev-1"),
            api: api
        )
    }

    @Test("items(in:) maps a transcode item: ticks→seconds, api_key URLs, audio + subtitle tracks")
    func itemsMapping() async throws {
        let api = RecordingAPIClient()
        let json = #"""
        {"Items":[{"Id":"42","Name":"Movie","Type":"Movie","ProductionYear":2020,
          "RunTimeTicks":60000000000,"Overview":"x","ImageTags":{"Primary":"tag1"},
          "MediaSources":[{"Id":"42","Container":"mkv","MediaStreams":[
            {"Index":1,"Type":"Audio","DisplayTitle":"English","Language":"eng","Codec":"aac","Channels":6,"IsDefault":true},
            {"Index":2,"Type":"Subtitle","DisplayTitle":"English","Language":"eng","Codec":"srt"}
          ]}]}],"TotalRecordCount":1}
        """#
        await api.enqueue(.init(data: Data(json.utf8), statusCode: 200, headers: [:]))

        let source = makeSource(api: api)
        let libraryID = Library.ID(source: .jellyfin(serverID: "http://jelly.test:8096"), rawValue: "lib1")
        let items = try await source.items(in: libraryID)

        let item = try #require(items.first)
        #expect(item.title == "Movie")
        #expect(item.runtime == .seconds(6000))
        #expect(item.streamURL?.path.contains("master.m3u8") == true)

        let streamURL = try #require(item.streamURL)
        let streamComponents = try #require(URLComponents(url: streamURL, resolvingAgainstBaseURL: false))
        #expect(streamComponents.queryItems?.first { $0.name == "api_key" }?.value == "tok")

        #expect(item.audioTracks.map(\.id) == ["1"])
        #expect(item.selectedAudioTrackID == "1")
        #expect(item.subtitleTracks.map(\.id) == ["2"])

        let poster = try #require(item.posterURL)
        #expect(poster.path.contains("/Items/42/Images/Primary"))
        #expect(URLComponents(url: poster, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "api_key" } == true)
    }

    @Test("resolvePlayback transcode: fresh session, api_key + stream indexes + offset")
    func resolveTranscode() async throws {
        let source = makeSource(api: RecordingAPIClient())
        let request = PlaybackRequest(
            itemID: .init(source: .jellyfin(serverID: "http://jelly.test:8096"), rawValue: "42"),
            mode: .transcode,
            audioStreamID: "1",
            subtitleStreamID: "2",
            startTime: .seconds(90)
        )

        let first = try await source.resolvePlayback(request)
        let second = try await source.resolvePlayback(request)

        #expect(first.isServerTranscode)
        #expect(first.baseOffsetSeconds == 90)

        let c1 = try #require(URLComponents(url: first.url, resolvingAgainstBaseURL: false))
        #expect(c1.path.contains("/Videos/42/master.m3u8"))
        #expect(c1.queryItems?.first { $0.name == "api_key" }?.value == "tok")
        #expect(c1.queryItems?.first { $0.name == "AudioStreamIndex" }?.value == "1")
        #expect(c1.queryItems?.first { $0.name == "SubtitleStreamIndex" }?.value == "2")
        #expect(c1.queryItems?.first { $0.name == "startTimeTicks" }?.value == "900000000")

        // Fresh PlaySessionId each resolve (the -1008-style safety).
        let s1 = c1.queryItems?.first { $0.name == "PlaySessionId" }?.value
        let s2 = URLComponents(url: second.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "PlaySessionId" }?.value
        #expect(s1 != nil)
        #expect(s1 != s2)
    }

    @Test("resolvePlayback subtitle off → SubtitleStreamIndex=-1")
    func resolveSubtitleOff() async throws {
        let source = makeSource(api: RecordingAPIClient())
        let request = PlaybackRequest(
            itemID: .init(source: .jellyfin(serverID: "http://jelly.test:8096"), rawValue: "42"),
            mode: .transcode,
            subtitleStreamID: "0"
        )
        let resolved = try await source.resolvePlayback(request)
        let c = try #require(URLComponents(url: resolved.url, resolvingAgainstBaseURL: false))
        #expect(c.queryItems?.first { $0.name == "SubtitleStreamIndex" }?.value == "-1")
    }

    @Test("resolvePlayback direct play returns the stable URL untouched")
    func resolveDirect() async throws {
        let source = makeSource(api: RecordingAPIClient())
        let fileURL = URL(string: "http://jelly.test:8096/Videos/7/stream?static=true&mediaSourceId=7&api_key=tok")!
        let request = PlaybackRequest(
            itemID: .init(source: .jellyfin(serverID: "http://jelly.test:8096"), rawValue: "7"),
            mode: .directPlay,
            directPlayURL: fileURL
        )
        let resolved = try await source.resolvePlayback(request)
        #expect(resolved.url == fileURL)
        #expect(resolved.isServerTranscode == false)
    }

    @Test("supports downloads; Original uses /Items/{id}/Download, caps use a progressive mp4")
    func downloads() async throws {
        let source = makeSource(api: RecordingAPIClient())
        #expect(source.supportsDownloads == true)

        let item = MediaItem(
            id: .init(source: .jellyfin(serverID: "http://jelly.test:8096"), rawValue: "42"),
            title: "Movie",
            kind: .movie
        )

        // Original → raw-file download endpoint, with the token.
        let original = try #require(try await source.downloadURL(for: item, quality: .original))
        #expect(original.path.contains("/Items/42/Download"))
        let originalQuery = try #require(URLComponents(url: original, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(originalQuery.contains { $0.name == "api_key" && $0.value == "tok" })

        // A bitrate cap → progressive mp4 transcode with bitrate + height caps.
        let capped = try #require(try await source.downloadURL(for: item, quality: .bitrate8Mbps1080p))
        #expect(capped.path.contains("/Videos/42/stream.mp4"))
        let cappedQuery = try #require(URLComponents(url: capped, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(cappedQuery.contains { $0.name == "VideoBitrate" && $0.value == "8000000" })
        #expect(cappedQuery.contains { $0.name == "MaxHeight" && $0.value == "1080" })
        #expect(cappedQuery.contains { $0.name == "static" && $0.value == "false" })
    }
}

@Suite("Jellyfin — ProviderIds decoding")
struct JellyfinProviderIdsTests {
    @Test("BaseItemDto maps ProviderIds (case-insensitive) into typed external IDs")
    func providerIds() throws {
        let json = #"""
        {"Id":"42","Name":"The Matrix","Type":"Movie",
         "ProviderIds":{"Tmdb":"603","Imdb":"tt0133093","Tvdb":"1234"}}
        """#
        let dto = try JSONDecoder().decode(JellyfinAPI.BaseItemDto.self, from: Data(json.utf8))
        #expect(dto.guids.tmdb == "603")
        #expect(dto.guids.imdb == "tt0133093")
        #expect(dto.guids.tvdb == "1234")
    }

    @Test("BaseItemDto without ProviderIds yields empty external IDs")
    func noProviderIds() throws {
        let json = #"{"Id":"42","Name":"X","Type":"Movie"}"#
        let dto = try JSONDecoder().decode(JellyfinAPI.BaseItemDto.self, from: Data(json.utf8))
        #expect(dto.guids.isEmpty)
    }
}

@Suite("Jellyfin — watched state")
struct JellyfinWatchedTests {
    @Test("UserData.Played == true → isWatched")
    func playedTrue() throws {
        let json = #"{"Id":"42","Name":"X","Type":"Movie","UserData":{"Played":true}}"#
        let dto = try JSONDecoder().decode(JellyfinAPI.BaseItemDto.self, from: Data(json.utf8))
        #expect(dto.isWatched)
    }

    @Test("UserData.Played == false → not watched")
    func playedFalse() throws {
        let json = #"{"Id":"42","Name":"X","Type":"Movie","UserData":{"Played":false}}"#
        let dto = try JSONDecoder().decode(JellyfinAPI.BaseItemDto.self, from: Data(json.utf8))
        #expect(!dto.isWatched)
    }

    @Test("UserData.IsFavorite → isFavorite")
    func favoriteDecodes() throws {
        let yes = #"{"Id":"42","Name":"X","Type":"Movie","UserData":{"IsFavorite":true}}"#
        let no  = #"{"Id":"42","Name":"X","Type":"Movie","UserData":{"IsFavorite":false}}"#
        let none = #"{"Id":"42","Name":"X","Type":"Movie"}"#
        #expect(try JSONDecoder().decode(JellyfinAPI.BaseItemDto.self, from: Data(yes.utf8)).isFavorite)
        #expect(try !JSONDecoder().decode(JellyfinAPI.BaseItemDto.self, from: Data(no.utf8)).isFavorite)
        #expect(try !JSONDecoder().decode(JellyfinAPI.BaseItemDto.self, from: Data(none.utf8)).isFavorite)
    }

    @Test("No UserData → not watched")
    func noUserData() throws {
        let json = #"{"Id":"42","Name":"X","Type":"Movie"}"#
        let dto = try JSONDecoder().decode(JellyfinAPI.BaseItemDto.self, from: Data(json.utf8))
        #expect(!dto.isWatched)
    }

    @Test("UserData.UnplayedItemCount decodes for a season (On Deck)")
    func unplayedItemCount() throws {
        let json = #"{"Id":"7","Name":"Season 1","Type":"Season","UserData":{"UnplayedItemCount":3}}"#
        let dto = try JSONDecoder().decode(JellyfinAPI.BaseItemDto.self, from: Data(json.utf8))
        #expect(dto.userData?.unplayedItemCount == 3)
    }
}

@Suite("Jellyfin — rich metadata")
struct JellyfinMetadataTests {
    @Test("Series DTO decodes genres, rating, counts, status + dates")
    func seriesMetadata() throws {
        let json = #"""
        {"Id":"7","Name":"Game of Thrones","Type":"Series",
         "Genres":["Drama","Fantasy"],"CommunityRating":9.3,
         "ChildCount":8,"RecursiveItemCount":73,"Status":"Ended",
         "PremiereDate":"2011-04-17T00:00:00.0000000Z",
         "EndDate":"2019-05-19T00:00:00.0000000Z",
         "DateCreated":"2020-01-02T03:04:05.0000000Z"}
        """#
        let dto = try JSONDecoder().decode(JellyfinAPI.BaseItemDto.self, from: Data(json.utf8))
        #expect(dto.genreList == ["Drama", "Fantasy"])
        #expect(dto.communityRating == 9.3)
        #expect(dto.childCount == 8)
        #expect(dto.recursiveItemCount == 73)
        #expect(dto.endYear == 2019)
        // PremiereDate → 2011-04-17
        let cal = Calendar(identifier: .gregorian)
        let release = try #require(dto.releaseDate)
        #expect(cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: release).year == 2011)
        #expect(dto.dateAdded != nil)
    }

    @Test("Continuing series has no end year (renders as Present)")
    func continuingNoEndYear() throws {
        let json = #"""
        {"Id":"8","Name":"Ongoing Show","Type":"Series","Status":"Continuing",
         "EndDate":"2030-01-01T00:00:00.0000000Z"}
        """#
        let dto = try JSONDecoder().decode(JellyfinAPI.BaseItemDto.self, from: Data(json.utf8))
        #expect(dto.endYear == nil)
        #expect(dto.status == "Continuing")
    }

    @Test("Missing metadata fields decode to nil / empty")
    func missingMetadata() throws {
        let json = #"{"Id":"9","Name":"Bare","Type":"Movie"}"#
        let dto = try JSONDecoder().decode(JellyfinAPI.BaseItemDto.self, from: Data(json.utf8))
        #expect(dto.genreList.isEmpty)
        #expect(dto.communityRating == nil)
        #expect(dto.releaseDate == nil)
        #expect(dto.dateAdded == nil)
        #expect(dto.endYear == nil)
        #expect(dto.childCount == nil)
        #expect(dto.recursiveItemCount == nil)
    }

    @Test("ISO-8601 date parses with and without fractional seconds")
    func dateParsing() throws {
        #expect(JellyfinAPI.BaseItemDto.parseDate("2011-04-17T00:00:00.0000000Z") != nil)
        #expect(JellyfinAPI.BaseItemDto.parseDate("2011-04-17T00:00:00Z") != nil)
        #expect(JellyfinAPI.BaseItemDto.parseDate(nil) == nil)
        #expect(JellyfinAPI.BaseItemDto.parseDate("") == nil)
    }
}

@Suite("Jellyfin — media segments")
struct JellyfinMediaSegmentsTests {
    @Test("MediaSegmentDto maps ticks + type to a PlaybackSegment")
    func mapsIntro() throws {
        let json = #"{"Type":"Intro","StartTicks":100000000,"EndTicks":900000000}"#
        let dto = try JSONDecoder().decode(JellyfinAPI.MediaSegmentDto.self, from: Data(json.utf8))
        let seg = try #require(dto.segment)
        #expect(seg.kind == .intro)
        #expect(seg.start == 10)   // 100_000_000 ticks / 1e7 = 10s
        #expect(seg.end == 90)
    }

    @Test("Outro maps to credits")
    func outroToCredits() throws {
        let json = #"{"Type":"Outro","StartTicks":12000000000,"EndTicks":13000000000}"#
        let dto = try JSONDecoder().decode(JellyfinAPI.MediaSegmentDto.self, from: Data(json.utf8))
        #expect(dto.segment?.kind == .credits)
    }

    @Test("Response decodes the Items wrapper and compacts to segments")
    func decodesWrapper() throws {
        let json = #"""
        {"Items":[
          {"Type":"Intro","StartTicks":0,"EndTicks":50000000},
          {"Type":"Unknown","StartTicks":0,"EndTicks":1}
        ],"TotalRecordCount":2}
        """#
        let resp = try JSONDecoder().decode(JellyfinAPI.MediaSegmentsResponse.self, from: Data(json.utf8))
        let segs = resp.items.compactMap(\.segment)
        #expect(segs.count == 1)          // unknown type dropped
        #expect(segs[0].kind == .intro)
    }
}

@Suite("Jellyfin — PlaybackInfo resume")
struct JellyfinPlaybackInfoTests {
    private let base = URL(string: "http://jelly.test:8096")!

    private func makeSource(api: any APIClient) -> JellyfinMediaSource {
        JellyfinMediaSource(
            serverID: "http://jelly.test:8096",
            displayName: "Den",
            baseURL: base,
            accessToken: "tok",
            userID: "u1",
            configuration: JellyfinConfiguration(client: "Aether", version: "0.2.0", deviceName: "Test", deviceID: "dev-1"),
            api: api
        )
    }

    private func transcodeItem() -> MediaItem {
        // An .m3u8 streamURL makes `isServerTranscode` true → the transcode path.
        MediaItem(
            id: .init(source: .jellyfin(serverID: "http://jelly.test:8096"), rawValue: "ep1"),
            title: "Episode 1", kind: .episode,
            streamURL: URL(string: "http://jelly.test:8096/Videos/ep1/master.m3u8?api_key=tok")!
        )
    }

    @Test("Resume goes through PlaybackInfo and uses the server's TranscodingUrl")
    func usesPlaybackInfo() async throws {
        let api = RecordingAPIClient()
        let json = #"""
        {"MediaSources":[{"Id":"ep1","SupportsTranscoding":true,
          "TranscodingUrl":"/videos/ep1/master.m3u8?api_key=tok&PlaySessionId=abc&VideoCodec=h264"}],
         "PlaySessionId":"abc"}
        """#
        await api.enqueue(.init(data: Data(json.utf8), statusCode: 200, headers: [:]))

        let source = makeSource(api: api)
        let request = PlaybackRequest(item: transcodeItem(), startTime: .seconds(120))
        let resolved = try await source.resolvePlayback(request)

        #expect(resolved.isServerTranscode)
        #expect(resolved.transcodeSessionID == "abc")
        let urlString = resolved.url.absoluteString
        #expect(urlString.hasPrefix("http://jelly.test:8096/videos/ep1/master.m3u8"))
        #expect(urlString.contains("PlaySessionId=abc"))

        let req = try #require(await api.requests.first)
        #expect(req.url?.path == "/Items/ep1/PlaybackInfo")
        #expect(req.httpMethod == "POST")
        #expect(req.url?.query?.contains("StartTimeTicks=1200000000") == true)
    }

    @Test("PlaybackInfo failure falls back to the hand-built HLS URL")
    func fallsBackOnFailure() async throws {
        let api = RecordingAPIClient()
        await api.enqueue(.init(data: Data("err".utf8), statusCode: 500, headers: [:]))

        let source = makeSource(api: api)
        let request = PlaybackRequest(item: transcodeItem(), startTime: .seconds(120))
        let resolved = try await source.resolvePlayback(request)

        #expect(resolved.isServerTranscode)
        #expect(resolved.url.path == "/Videos/ep1/master.m3u8")   // legacy hand-built
    }
}
