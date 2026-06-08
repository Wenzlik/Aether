import Testing
import Foundation
@testable import AetherCore

@Suite("AetherCore — Foundation")
struct AetherCoreFoundationTests {

    @Test("MockMediaSource (sample init) lists at least one library and one item")
    func mockSourceHasContent() async throws {
        let source = MockMediaSource()
        let libraries = try await source.libraries()
        try #require(!libraries.isEmpty)

        let items = try await source.items(in: libraries[0].id)
        try #require(!items.isEmpty)
        #expect(items[0].streamURL != nil)
    }

    @Test("ResumeStore round-trips a resume point")
    func resumeStoreRoundTrip() async {
        let store = ResumeStore()
        let id = MediaID(source: .mock, rawValue: "x")
        await store.record(.init(mediaID: id, position: .seconds(42)))

        let point = await store.point(for: id)
        #expect(point?.position == .seconds(42))
    }
}

@Suite("AetherCore — PlaybackSession")
struct PlaybackSessionTests {

    private static let testURL = URL(string: "https://example.com/sample.m3u8")!

    private static func makeItem(id: String = "test", streamURL: URL? = testURL) -> MediaItem {
        MediaItem(
            id: .init(source: .mock, rawValue: id),
            title: "Test",
            kind: .movie,
            streamURL: streamURL
        )
    }

    @Test("sanitizedResume clamps corrupt / out-of-range saved points")
    func sanitizedResumeClamps() {
        let twoHours = Duration.seconds(7200)
        // In-range resume is kept.
        #expect(PlaybackSession.sanitizedResume(3600, runtime: twoHours) == 3600)
        // At/over the runtime → start over (the pre-fix bug could save 5h on a 2h film).
        #expect(PlaybackSession.sanitizedResume(7200, runtime: twoHours) == 0)
        #expect(PlaybackSession.sanitizedResume(18000, runtime: twoHours) == 0)
        // Non-positive / non-finite → 0.
        #expect(PlaybackSession.sanitizedResume(0, runtime: twoHours) == 0)
        #expect(PlaybackSession.sanitizedResume(-5, runtime: twoHours) == 0)
        #expect(PlaybackSession.sanitizedResume(.nan, runtime: twoHours) == 0)
        // Unknown runtime → keep a positive value (can't bound it).
        #expect(PlaybackSession.sanitizedResume(3600, runtime: nil) == 3600)
    }

    @Test("idle → loading → playing → paused on a valid item")
    func transitions() async {
        let session = PlaybackSession(resumeStore: ResumeStore(), resumeWriteInterval: .seconds(60))

        var state = await session.state
        #expect(state.status == .idle)

        await session.prepare(item: Self.makeItem())
        state = await session.state
        #expect(state.status == .loading)
        #expect(state.item?.id.rawValue == "test")

        await session.play()
        state = await session.state
        #expect(state.status == .playing)

        await session.pause()
        state = await session.state
        #expect(state.status == .paused)
    }

    @Test("Item with no streamURL transitions to .failed")
    func noStreamFails() async {
        let session = PlaybackSession(resumeStore: ResumeStore(), resumeWriteInterval: .seconds(60))
        let item = Self.makeItem(id: "no-stream", streamURL: nil)

        await session.prepare(item: item)
        let state = await session.state
        #expect(state.status == .failed)
        #expect(state.item?.id == item.id)
    }

    @Test("pause() writes a resume point to the store")
    func resumeOnPause() async throws {
        let store = ResumeStore()
        let session = PlaybackSession(resumeStore: store, resumeWriteInterval: .seconds(60))
        let item = Self.makeItem(id: "with-resume")

        await session.prepare(item: item)
        await session.play()
        await session.pause()

        let point = await store.point(for: item.id)
        try #require(point != nil)
    }

    @Test("stop() resets state to idle and clears the item")
    func stopResets() async {
        let session = PlaybackSession(resumeStore: ResumeStore(), resumeWriteInterval: .seconds(60))

        await session.prepare(item: Self.makeItem())
        await session.play()
        await session.stop()

        let state = await session.state
        #expect(state.status == .idle)
        #expect(state.item == nil)
    }

    @Test("markFailed() clears the current AVPlayer")
    func markFailedClearsPlayer() async {
        let session = PlaybackSession(resumeStore: ResumeStore(), resumeWriteInterval: .seconds(60))
        let item = Self.makeItem(id: "bad-stream")

        await session.prepare(item: item)
        #expect(await session.currentAVPlayer() != nil)

        await session.markFailed(message: "Codec unsupported")

        let state = await session.state
        #expect(state.status == .failed)
        #expect(state.item?.id == item.id)
        #expect(state.error == "Codec unsupported")
        #expect(await session.currentAVPlayer() == nil)
    }

    @Test("prepare() resumes from a previously stored position")
    func resumesFromStore() async {
        let store = ResumeStore()
        let item = Self.makeItem(id: "with-existing-resume")
        await store.record(.init(mediaID: item.id, position: .seconds(120)))

        let session = PlaybackSession(resumeStore: store, resumeWriteInterval: .seconds(60))
        await session.prepare(item: item)

        let state = await session.state
        #expect(state.position == .seconds(120))
    }
}

/// Records the `PlaybackRequest`s a session sends and returns canned, distinct
/// `ResolvedPlayback`s — so tests can assert the session resolves a *fresh* URL
/// per call instead of replaying a stale one.
private actor SpyPlaybackSource: MediaSource {
    let id: MediaSourceID = .mock
    let displayName = "Spy"
    private(set) var requests: [PlaybackRequest] = []
    private(set) var stoppedSessions: [String] = []
    private var callCount = 0
    private let shouldFail: Bool

    init(shouldFail: Bool = false) { self.shouldFail = shouldFail }

    func libraries() async throws -> [Library] { [] }
    func items(in library: Library.ID) async throws -> [MediaItem] { [] }

    func resolvePlayback(_ request: PlaybackRequest) async throws -> ResolvedPlayback {
        requests.append(request)
        if shouldFail { throw PlaybackResolveError.noPlayableStream }
        callCount += 1
        let offset = request.startTime.map { Double($0.components.seconds) } ?? 0
        let transcode = request.mode == .transcode
        return ResolvedPlayback(
            url: URL(string: "https://resolved.example/\(callCount).m3u8")!,
            isServerTranscode: transcode,
            baseOffsetSeconds: transcode ? offset : 0,
            transcodeSessionID: transcode ? "session-\(callCount)" : nil
        )
    }

    func stopTranscode(sessionID: String) async {
        stoppedSessions.append(sessionID)
    }
}

@Suite("AetherCore — Playback URL lifecycle")
struct PlaybackURLLifecycleTests {

    private static func transcodeItem(
        id: String = "42",
        audioID: String? = "11",
        subtitleID: String? = nil
    ) -> MediaItem {
        let url = URL(string: "https://lan.example/video/:/transcode/universal/start.m3u8?session=old")!
        return MediaItem(
            id: .init(source: .mock, rawValue: id),
            title: "T",
            kind: .movie,
            streamURL: url,
            audioTracks: [
                MediaAudioTrack(id: "11", title: "English", isSelected: audioID == "11"),
                MediaAudioTrack(id: "12", title: "Czech", isSelected: audioID == "12")
            ],
            selectedAudioTrackID: audioID,
            subtitleTracks: subtitleID.map { [MediaSubtitleTrack(id: $0, title: "Subs", isSelected: true)] } ?? [],
            selectedSubtitleTrackID: subtitleID
        )
    }

    @Test("PlaybackRequest(item:) carries mode + selected streams for a transcode item")
    func requestFromTranscodeItem() {
        let item = Self.transcodeItem(audioID: "11", subtitleID: "20")
        let request = PlaybackRequest(item: item, startTime: .seconds(30))
        #expect(request.mode == .transcode)
        #expect(request.audioStreamID == "11")
        #expect(request.subtitleStreamID == "20")
        #expect(request.directPlayURL == nil)
        #expect(request.startTime == .seconds(30))
    }

    @Test("PlaybackRequest(item:) carries the stable direct-play URL for a direct item")
    func requestFromDirectItem() {
        let url = URL(string: "https://lan.example/library/parts/7/1/file.mp4")!
        let item = MediaItem(id: .init(source: .mock, rawValue: "7"), title: "D", kind: .movie, streamURL: url)
        let request = PlaybackRequest(item: item, startTime: nil)
        #expect(request.mode == .directPlay)
        #expect(request.directPlayURL == url)
    }

    @Test("prepare(source:) resolves a fresh URL via the source with the selected audio + resume offset")
    func prepareResolvesViaSource() async {
        let spy = SpyPlaybackSource()
        let item = Self.transcodeItem(audioID: "11")
        let session = PlaybackSession(resumeStore: ResumeStore(), resumeWriteInterval: .seconds(60))

        await session.prepare(item: item, source: spy, startAt: 120)

        let requests = await spy.requests
        #expect(requests.count == 1)
        #expect(requests.first?.itemID == item.id)
        #expect(requests.first?.mode == .transcode)
        #expect(requests.first?.audioStreamID == "11")
        #expect(requests.first?.startTime == .seconds(120))

        let state = await session.state
        #expect(state.status == .loading)
    }

    @Test("selectingAudioTrack updates state only — no URL mutation, no resolve")
    func selectingAudioTrackIsStateOnly() async {
        // In the new pipeline, the player no longer switches tracks mid-stream.
        // The audio / subtitle pickers live on Detail and only update the
        // item's selection state; the source layer PUTs the choice and asks
        // Plex for a fresh decision when the user presses Play. So changing
        // the track on a `MediaItem` must NOT alter `streamURL`.
        let item = Self.transcodeItem(audioID: "11")
        let originalURL = item.streamURL

        let switched = item.selectingAudioTrack(MediaAudioTrack(id: "12", title: "Czech"))

        #expect(switched.selectedAudioTrackID == "12")
        #expect(switched.streamURL == originalURL) // URL is identical
    }

    @Test("stop() stops the active transcode session")
    func stopStopsTranscodeSession() async {
        let spy = SpyPlaybackSource()
        let session = PlaybackSession(resumeStore: ResumeStore(), resumeWriteInterval: .seconds(60))

        await session.prepare(item: Self.transcodeItem(), source: spy, startAt: 0)
        await session.stop()

        let stopped = await spy.stoppedSessions
        #expect(stopped == ["session-1"])
    }

    @Test("a resolve failure surfaces a controlled .failed state, never a black screen")
    func resolveFailureIsControlled() async {
        let spy = SpyPlaybackSource(shouldFail: true)
        let item = Self.transcodeItem()
        let session = PlaybackSession(resumeStore: ResumeStore(), resumeWriteInterval: .seconds(60))

        await session.prepare(item: item, source: spy, startAt: 0)

        let state = await session.state
        #expect(state.status == .failed)
        #expect(state.item?.id == item.id)
        #expect(state.error != nil)
        #expect(await session.currentAVPlayer() == nil)
    }

    @Test("recoverOrFail auto-re-prepares once, then fails on a second consecutive failure")
    func autoRecoversOnceThenFails() async {
        let spy = SpyPlaybackSource()
        let session = PlaybackSession(resumeStore: ResumeStore(), resumeWriteInterval: .seconds(60))

        await session.prepare(item: Self.transcodeItem(), source: spy, startAt: 0)
        await session.play()
        let initialResolves = await spy.requests.count   // 1

        // First failure → one automatic recovery (a fresh resolve), not failed.
        await session.recoverOrFail(message: "boom")
        #expect(await spy.requests.count == initialResolves + 1)
        #expect(await session.state.status != .failed)

        // Second consecutive failure (no healthy playback between) → give up.
        await session.recoverOrFail(message: "boom again")
        #expect(await session.state.status == .failed)
        #expect(await spy.requests.count == initialResolves + 1)  // no further resolve
    }

    @Test("a fresh user open re-arms auto-recovery")
    func freshOpenReArmsRecovery() async {
        let spy = SpyPlaybackSource()
        let session = PlaybackSession(resumeStore: ResumeStore(), resumeWriteInterval: .seconds(60))

        await session.prepare(item: Self.transcodeItem(), source: spy, startAt: 0)
        await session.play()
        await session.recoverOrFail(message: "boom")        // uses the budget
        await session.recoverOrFail(message: "boom again")  // exhausted → failed
        #expect(await session.state.status == .failed)

        // A new user-initiated open resets the budget…
        await session.prepare(item: Self.transcodeItem(), source: spy, startAt: 0)
        await session.play()
        let before = await spy.requests.count
        await session.recoverOrFail(message: "boom")        // …so recovery works again
        #expect(await spy.requests.count == before + 1)
        #expect(await session.state.status != .failed)
    }
}

@Suite("AetherCore — MockFixture")
struct MockFixtureTests {

    @Test("MockFixture decodes the canonical schema")
    func fixtureDecodes() throws {
        let json = #"""
        {
          "sampleStreamURL": "https://example.com/sample.m3u8",
          "libraries": [
            { "id": "movies", "title": "Movies", "kind": "movie" }
          ],
          "items": [
            { "id": "x", "title": "X", "kind": "movie", "library": "movies", "year": 2024, "runtimeSeconds": 6000, "summary": "x." }
          ],
          "featured": ["x"],
          "resumePoints": [{ "itemID": "x", "positionSeconds": 120 }]
        }
        """#
        let data = Data(json.utf8)
        let fixture = try JSONDecoder().decode(MockFixture.self, from: data)
        #expect(fixture.libraries.count == 1)
        #expect(fixture.items.count == 1)
        #expect(fixture.featured == ["x"])
        #expect(fixture.resumePoints.first?.positionSeconds == 120)
    }

    @Test("MockMediaSource(fixture:) groups items by library and falls back to sampleStreamURL")
    func fixtureBacked() async throws {
        let fixture = MockFixture(
            sampleStreamURL: "https://example.com/sample.m3u8",
            libraries: [.init(id: "movies", title: "Movies", kind: .movie)],
            items: [
                .init(id: "x", title: "X", kind: .movie, library: "movies",
                      year: 2024, runtimeSeconds: 6000, summary: nil,
                      posterURL: nil, backdropURL: nil, streamURL: nil)
            ],
            featured: ["x"],
            resumePoints: [.init(itemID: "x", positionSeconds: 60)]
        )

        let source = MockMediaSource(fixture: fixture)
        let libs = try await source.libraries()
        #expect(libs.count == 1)

        let items = try await source.items(in: libs[0].id)
        #expect(items.count == 1)
        #expect(items[0].streamURL?.absoluteString == "https://example.com/sample.m3u8")

        let featured = await source.featuredItems
        #expect(featured.map(\.id.rawValue) == ["x"])

        let resume = await source.simulatedResumePoints
        #expect(resume.first?.position == .seconds(60))
    }
}

@Suite("AetherCore — HomeFeedBuilder")
struct HomeFeedBuilderTests {

    @Test("Continue Watching includes only items with a resume point, most recent first")
    func continueWatchingFiltering() async throws {
        let fixture = MockFixture(
            sampleStreamURL: "https://example.com/sample.m3u8",
            libraries: [.init(id: "movies", title: "Movies", kind: .movie)],
            items: [
                .init(id: "a", title: "A", kind: .movie, library: "movies",
                      year: nil, runtimeSeconds: 3600, summary: nil,
                      posterURL: nil, backdropURL: nil, streamURL: nil),
                .init(id: "b", title: "B", kind: .movie, library: "movies",
                      year: nil, runtimeSeconds: 3600, summary: nil,
                      posterURL: nil, backdropURL: nil, streamURL: nil),
                .init(id: "c", title: "C", kind: .movie, library: "movies",
                      year: nil, runtimeSeconds: 3600, summary: nil,
                      posterURL: nil, backdropURL: nil, streamURL: nil)
            ],
            featured: ["a"],
            resumePoints: []
        )
        let source = MockMediaSource(fixture: fixture)
        let store = ResumeStore()

        let now = Date()
        await store.record(.init(mediaID: .init(source: .mock, rawValue: "a"),
                                 position: .seconds(60),
                                 updatedAt: now.addingTimeInterval(-300)))
        await store.record(.init(mediaID: .init(source: .mock, rawValue: "c"),
                                 position: .seconds(120),
                                 updatedAt: now))

        let feed = try await HomeFeedBuilder().build(
            source: source,
            resumeStore: store,
            featured: await source.featuredItems
        )

        #expect(feed.continueWatching.map(\.item.id.rawValue) == ["c", "a"])
        #expect(feed.featured.map(\.id.rawValue) == ["a"])
    }

    @Test("ContinueWatchingEntry.progress is fraction of runtime")
    func progressFraction() {
        let item = MediaItem(
            id: .init(source: .mock, rawValue: "x"),
            title: "x",
            kind: .movie,
            runtime: .seconds(1000)
        )
        let entry = HomeFeed.ContinueWatchingEntry(
            item: item,
            resume: .init(mediaID: item.id, position: .seconds(250))
        )
        #expect(entry.progress == 0.25)
    }
}

@Suite("AetherCore — MediaGuids")
struct MediaGuidsTests {
    @Test("parses tmdb/imdb/tvdb provider-prefixed strings, ignores unknown")
    func parseGuidStrings() {
        let g = MediaGuids(guidStrings: [
            "tmdb://603", "imdb://tt0133093", "tvdb://1234", "plex://movie/abc"
        ])
        #expect(g.tmdb == "603")
        #expect(g.imdb == "tt0133093")
        #expect(g.tvdb == "1234")
        #expect(g.isEmpty == false)
    }

    @Test("empty when nothing matches")
    func empty() {
        #expect(MediaGuids(guidStrings: ["plex://movie/abc"]).isEmpty)
        #expect(MediaGuids().isEmpty)
    }
}

@Suite("AetherCore — UnifiedLibrary merge")
struct UnifiedLibraryTests {
    private func plex(_ id: String, _ title: String, year: Int? = nil,
                      tmdb: String? = nil, imdb: String? = nil, stream: Bool = true) -> MediaItem {
        MediaItem(id: .init(source: .plex(serverID: "s1"), rawValue: id), title: title, kind: .movie,
                  year: year, streamURL: stream ? URL(string: "http://p/\(id)") : nil,
                  guids: MediaGuids(tmdb: tmdb, imdb: imdb))
    }
    private func jelly(_ id: String, _ title: String, year: Int? = nil,
                       tmdb: String? = nil, imdb: String? = nil) -> MediaItem {
        MediaItem(id: .init(source: .jellyfin(serverID: "j1"), rawValue: id), title: title, kind: .movie,
                  year: year, streamURL: URL(string: "http://j/\(id)"),
                  guids: MediaGuids(tmdb: tmdb, imdb: imdb))
    }

    @Test("same TMDB → one item, two sources, priority-sorted")
    func mergeByTmdb() {
        let u = UnifiedLibrary.merge([plex("1", "Matrix", tmdb: "603"), jelly("9", "Matrix", tmdb: "603")])
        #expect(u.count == 1)
        #expect(u[0].sources.map(\.kind) == [.plex, .jellyfin])
        #expect(u[0].preferredSource?.kind == .plex)
    }

    @Test("cross-provider: merges on a shared IMDB even when one lacks TMDB")
    func crossProvider() {
        let u = UnifiedLibrary.merge([plex("1", "Matrix", tmdb: "603", imdb: "tt0133093"),
                                      jelly("9", "Matrix", imdb: "tt0133093")])
        #expect(u.count == 1)
        #expect(u[0].sources.count == 2)
    }

    @Test("title+year fallback merges; different year does not")
    func titleYearFallback() {
        let same = UnifiedLibrary.merge([plex("1", "The Matrix", year: 1999),
                                         jelly("9", "the matrix!", year: 1999)])
        #expect(same.count == 1)
        let diff = UnifiedLibrary.merge([plex("1", "The Matrix", year: 1999),
                                         jelly("9", "The Matrix", year: 2000)])
        #expect(diff.count == 2)
    }

    @Test("no external id and no year → never merges")
    func noIdNoYear() {
        let u = UnifiedLibrary.merge([plex("1", "Untitled"), jelly("9", "Untitled")])
        #expect(u.count == 2)
    }

    @Test("downloaded item gains an offline source and is preferred")
    func offlineSource() {
        let item = plex("1", "Matrix", tmdb: "603")
        let u = UnifiedLibrary.merge([item, jelly("9", "Matrix", tmdb: "603")],
                                     downloaded: [item.id])
        #expect(u.count == 1)
        #expect(u[0].isDownloaded)
        #expect(u[0].preferredSource?.kind == .offline)
        #expect(u[0].sources.map(\.kind) == [.offline, .plex, .jellyfin])
    }

    @Test("lead metadata (genres / rating / dates) propagates to the unified item")
    func leadMetadata() {
        let added = Date(timeIntervalSince1970: 1_700_000_000)
        let released = Date(timeIntervalSince1970: 900_000_000)
        let item = MediaItem(
            id: .init(source: .plex(serverID: "s1"), rawValue: "1"), title: "Matrix",
            kind: .movie, streamURL: URL(string: "http://p/1"), guids: MediaGuids(tmdb: "603"),
            genres: ["Sci-Fi", "Action"], communityRating: 8.7,
            releaseDate: released, dateAdded: added
        )
        let u = UnifiedLibrary.merge([item])
        #expect(u.count == 1)
        #expect(u[0].genres == ["Sci-Fi", "Action"])
        #expect(u[0].communityRating == 8.7)
        #expect(u[0].releaseDate == released)
        #expect(u[0].dateAdded == added)
    }
}

@Suite("AetherCore — UnifiedLibrary aggregator")
struct UnifiedLibraryAggregatorTests {
    private struct StubSource: MediaSource {
        let id: MediaSourceID
        let displayName: String
        let libs: [Library]
        let itemsByLib: [Library.ID: [MediaItem]]
        let failsLibraries: Bool

        func libraries() async throws -> [Library] {
            if failsLibraries { throw URLError(.badServerResponse) }
            return libs
        }
        func items(in id: Library.ID) async throws -> [MediaItem] { itemsByLib[id] ?? [] }
    }

    @Test("fans out across sources, merges by id, tolerates a failing source")
    func aggregate() async {
        let plexLib = Library(id: .init(source: .plex(serverID: "s1"), rawValue: "m"), title: "Movies", kind: .movie)
        let jellyLib = Library(id: .init(source: .jellyfin(serverID: "j1"), rawValue: "m"), title: "Movies", kind: .movie)
        let plexItem = MediaItem(id: .init(source: .plex(serverID: "s1"), rawValue: "1"), title: "Matrix",
                                 kind: .movie, streamURL: URL(string: "http://p/1"), guids: MediaGuids(tmdb: "603"))
        let jellyItem = MediaItem(id: .init(source: .jellyfin(serverID: "j1"), rawValue: "9"), title: "Matrix",
                                  kind: .movie, streamURL: URL(string: "http://j/9"), guids: MediaGuids(tmdb: "603"))

        let plex = StubSource(id: .plex(serverID: "s1"), displayName: "Plex",
                              libs: [plexLib], itemsByLib: [plexLib.id: [plexItem]], failsLibraries: false)
        let jelly = StubSource(id: .jellyfin(serverID: "j1"), displayName: "Den",
                               libs: [jellyLib], itemsByLib: [jellyLib.id: [jellyItem]], failsLibraries: false)
        let dead = StubSource(id: .plex(serverID: "dead"), displayName: "Dead",
                              libs: [], itemsByLib: [:], failsLibraries: true)

        let library = UnifiedLibrary(sources: [plex, jelly, dead])
        // forceRefresh so the process-shared TTL cache (keyed by source set)
        // never serves another test's mock catalog.
        let movies = await library.unifiedItems(kind: .movie, forceRefresh: true)

        #expect(movies.count == 1)
        #expect(movies[0].sources.map(\.kind) == [.plex, .jellyfin])
        #expect(movies[0].sources.first?.serverName == "Plex")
    }
}

@Suite("AetherCore — UnifiedLibrary home rails")
struct UnifiedHomeRailsTests {
    private struct Stub: MediaSource {
        let id: MediaSourceID
        let displayName: String
        let libs: [Library]
        let itemsByLib: [Library.ID: [MediaItem]]
        func libraries() async throws -> [Library] { libs }
        func items(in id: Library.ID) async throws -> [MediaItem] { itemsByLib[id] ?? [] }
    }

    @Test("splits unified items into Movies / TV Shows rails")
    func split() async {
        let movieLib = Library(id: .init(source: .plex(serverID: "s1"), rawValue: "mov"), title: "Movies", kind: .movie)
        let showLib = Library(id: .init(source: .plex(serverID: "s1"), rawValue: "tv"), title: "Shows", kind: .show)
        let movie = MediaItem(id: .init(source: .plex(serverID: "s1"), rawValue: "1"), title: "Matrix",
                              kind: .movie, streamURL: URL(string: "http://p/1"), guids: MediaGuids(tmdb: "603"))
        let show = MediaItem(id: .init(source: .plex(serverID: "s1"), rawValue: "2"), title: "Severance",
                             kind: .show, streamURL: URL(string: "http://p/2"), guids: MediaGuids(tvdb: "999"))
        let stub = Stub(id: .plex(serverID: "s1"), displayName: "Plex",
                        libs: [movieLib, showLib],
                        itemsByLib: [movieLib.id: [movie], showLib.id: [show]])

        let rails = await UnifiedLibrary(sources: [stub]).homeRails(resumeStore: ResumeStore(), forceRefresh: true)
        #expect(rails.movies.count == 1)
        #expect(rails.shows.count == 1)
        #expect(rails.movies.first?.title == "Matrix")
        #expect(rails.shows.first?.title == "Severance")
    }

    @Test("recentlyAdded sorts by add date, recentlyReleased by release date")
    func recencyRails() async {
        let lib = Library(id: .init(source: .plex(serverID: "s1"), rawValue: "mov"), title: "Movies", kind: .movie)
        func movie(_ id: String, _ title: String, added: TimeInterval, released: TimeInterval) -> MediaItem {
            MediaItem(id: .init(source: .plex(serverID: "s1"), rawValue: id), title: title, kind: .movie,
                      streamURL: URL(string: "http://p/\(id)"), guids: MediaGuids(tmdb: id),
                      releaseDate: Date(timeIntervalSince1970: released),
                      dateAdded: Date(timeIntervalSince1970: added))
        }
        // Newest-added is "B"; newest-released is "A".
        let a = movie("1", "A", added: 1_000, released: 9_000)
        let b = movie("2", "B", added: 9_000, released: 1_000)
        let stub = Stub(id: .plex(serverID: "s1"), displayName: "Plex",
                        libs: [lib], itemsByLib: [lib.id: [a, b]])

        let rails = await UnifiedLibrary(sources: [stub]).homeRails(resumeStore: ResumeStore(), forceRefresh: true)
        #expect(rails.recentlyAdded.first?.title == "B")
        #expect(rails.recentlyReleased.first?.title == "A")
        #expect(rails.recentlyAdded.count == 2)
    }

    @Test("recentlyAdded falls back to merge order when nothing is dated")
    func recencyFallback() async {
        let lib = Library(id: .init(source: .plex(serverID: "s1"), rawValue: "mov"), title: "Movies", kind: .movie)
        let undated = MediaItem(id: .init(source: .plex(serverID: "s1"), rawValue: "1"), title: "Undated",
                                kind: .movie, streamURL: URL(string: "http://p/1"), guids: MediaGuids(tmdb: "603"))
        let stub = Stub(id: .plex(serverID: "s1"), displayName: "Plex",
                        libs: [lib], itemsByLib: [lib.id: [undated]])

        let rails = await UnifiedLibrary(sources: [stub]).homeRails(resumeStore: ResumeStore(), forceRefresh: true)
        #expect(rails.recentlyAdded.count == 1)         // fallback kept it
        #expect(rails.recentlyReleased.isEmpty)         // no release date → hidden
    }
}

@Suite("AetherCore — Cinema presets")
struct CinemaPresetTests {
    @Test("relativeScale anchors medium at 1.0 and grows with size")
    func relativeScaleAnchored() {
        // One authored scene, sized in code: medium is the authored baseline.
        #expect(CinemaScreenPreset.medium.relativeScale == 1.0)
        let scales = CinemaScreenPreset.ordered.map(\.relativeScale)
        #expect(scales == scales.sorted())
        #expect(scales.allSatisfy { $0 >= 1.0 })
        // Each preset's scale tracks its width relative to medium.
        #expect(CinemaScreenPreset.imax.relativeScale
                == CinemaScreenPreset.imax.widthMetres / CinemaScreenPreset.medium.widthMetres)
    }

    @Test("widthMetres grows monotonically with size")
    func widthsOrdered() {
        let widths = CinemaScreenPreset.ordered.map(\.widthMetres)
        #expect(widths == widths.sorted())
        #expect(widths.first == CinemaScreenPreset.medium.widthMetres)
    }

    @Test("CinemaPreferencesStore persists the chosen preset")
    @MainActor
    func preferencesRoundTrip() {
        let suite = "cinema.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = CinemaPreferencesStore(defaults: defaults)
        #expect(store.screenPreset == .medium)   // default
        store.screenPreset = .imax

        // A fresh store over the same defaults reads the persisted value.
        let reloaded = CinemaPreferencesStore(defaults: defaults)
        #expect(reloaded.screenPreset == .imax)
    }

    @Test("CinemaSeat: middle is the authored origin; back is farther + higher")
    func seatGeometry() {
        // Middle = authored layout (no offset).
        #expect(CinemaSeat.middle.zOffsetMetres == 0)
        #expect(CinemaSeat.middle.yOffsetMetres == 0)
        // Back sits farther from the screen (-Z) and higher (room drops, -Y).
        #expect(CinemaSeat.back.zOffsetMetres < CinemaSeat.middle.zOffsetMetres)
        #expect(CinemaSeat.back.yOffsetMetres < CinemaSeat.middle.yOffsetMetres)
        // Front is closer (+Z) and lower (room up, +Y) than middle.
        #expect(CinemaSeat.front.zOffsetMetres > CinemaSeat.middle.zOffsetMetres)
        #expect(CinemaSeat.front.yOffsetMetres > CinemaSeat.middle.yOffsetMetres)
        // Each row back sits a bit higher than the one ahead (front→middle→back).
        let heights = CinemaSeat.ordered.map(\.yOffsetMetres)   // ordered front→back
        #expect(heights == heights.sorted(by: >))   // strictly descending room-Y = rising viewer
    }

    @Test("CinemaSeat persists in CinemaPreferencesStore")
    @MainActor
    func seatRoundTrip() {
        let suite = "cinema.seat.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = CinemaPreferencesStore(defaults: defaults)
        #expect(store.seat == .middle)   // default
        store.seat = .back
        #expect(CinemaPreferencesStore(defaults: defaults).seat == .back)
    }
}

@Suite("AetherCore — artwork cache keys")
struct ArtworkCacheKeyTests {
    @Test("Plex: token rotation = same key; path/size are part of the key")
    func plexKeys() {
        let thumb = URL(string: "https://s:32400/photo/:/transcode?url=/library/metadata/6/thumb/1&width=400&height=600&minSize=1&upscale=0&X-Plex-Token=AAA")!
        let thumbOtherToken = URL(string: "https://s:32400/photo/:/transcode?url=/library/metadata/6/thumb/1&width=400&height=600&minSize=1&upscale=0&X-Plex-Token=BBB")!
        // Only the token differs → same cache key (no re-download on token rotation).
        #expect(AetherImageCache.cacheKey(for: thumb) == AetherImageCache.cacheKey(for: thumbOtherToken))

        // Backdrop (different inner path + size) must NOT collide with the thumb.
        let backdrop = URL(string: "https://s:32400/photo/:/transcode?url=/library/metadata/6/art/1&width=1200&height=675&minSize=1&upscale=0&X-Plex-Token=AAA")!
        #expect(AetherImageCache.cacheKey(for: thumb) != AetherImageCache.cacheKey(for: backdrop))

        // Same thumb, larger requested size → different key (size is part of it).
        let detail = URL(string: "https://s:32400/photo/:/transcode?url=/library/metadata/6/thumb/1&width=600&height=900&minSize=1&upscale=0&X-Plex-Token=AAA")!
        #expect(AetherImageCache.cacheKey(for: thumb) != AetherImageCache.cacheKey(for: detail))
    }

    @Test("key is independent of query-item order")
    func orderIndependent() {
        let a = URL(string: "https://j/Items/9/Images/Primary?api_key=AAA&tag=abc&fillWidth=400&fillHeight=600&quality=85&format=Webp")!
        let b = URL(string: "https://j/Items/9/Images/Primary?fillHeight=600&format=Webp&tag=abc&quality=85&fillWidth=400&api_key=ZZZ")!
        #expect(AetherImageCache.cacheKey(for: a) == AetherImageCache.cacheKey(for: b))
    }

    @Test("Jellyfin: api_key stripped; tag + fill size kept")
    func jellyfinKeys() {
        let a = URL(string: "https://j/Items/9/Images/Primary?api_key=AAA&tag=abc&fillWidth=400&fillHeight=600&quality=85&format=Webp")!
        let b = URL(string: "https://j/Items/9/Images/Primary?api_key=BBB&tag=abc&fillWidth=400&fillHeight=600&quality=85&format=Webp")!
        #expect(AetherImageCache.cacheKey(for: a) == AetherImageCache.cacheKey(for: b))      // token-only diff

        let bigger = URL(string: "https://j/Items/9/Images/Primary?api_key=AAA&tag=abc&fillWidth=1200&fillHeight=675&quality=90&format=Webp")!
        #expect(AetherImageCache.cacheKey(for: a) != AetherImageCache.cacheKey(for: bigger))  // size diff

        let newArt = URL(string: "https://j/Items/9/Images/Primary?api_key=AAA&tag=zzz&fillWidth=400&fillHeight=600&quality=85&format=Webp")!
        #expect(AetherImageCache.cacheKey(for: a) != AetherImageCache.cacheKey(for: newArt))  // art changed (tag) → new key
    }
}

@Suite("AetherCore — ArtworkSource per-tier URLs")
struct ArtworkSourceTests {
    private let plexBase = URL(string: "https://s:32400")!
    private let jellyBase = URL(string: "https://j:8096")!

    @Test("Jellyfin mints fillWidth/Height per tier, keeps tag, requires it")
    func jellyfinTiers() throws {
        let art = ArtworkSource(
            provider: .jellyfin, base: jellyBase, token: "tok",
            posterPath: "/Items/9/Images/Primary", posterTag: "abc",
            backdropPath: "/Items/9/Images/Backdrop", backdropTag: "def"
        )
        let thumb = try #require(art.posterURL(.thumbnail))
        let q = Dictionary(uniqueKeysWithValues:
            (URLComponents(url: thumb, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value) })
        #expect(q["fillWidth"] == "400")
        #expect(q["fillHeight"] == "600")
        #expect(q["tag"] == "abc")
        #expect(q["format"] == "Webp")
        #expect(q["quality"] == "85")          // thumbnail/still = 85
        #expect(q["api_key"] == "tok")

        // A larger backdrop tier scales the box up and uses higher quality.
        let large = try #require(art.backdropURL(.backdropLarge))
        let lq = Dictionary(uniqueKeysWithValues:
            (URLComponents(url: large, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value) })
        #expect(lq["fillWidth"] == "1920")
        #expect(lq["fillHeight"] == "1080")
        #expect(lq["quality"] == "90")
        #expect(lq["tag"] == "def")

        // No tag → no URL (Jellyfin can't size an image it can't address).
        let noTag = ArtworkSource(provider: .jellyfin, base: jellyBase, token: "tok",
                                  posterPath: "/Items/9/Images/Primary", posterTag: nil,
                                  backdropPath: nil)
        #expect(noTag.posterURL(.thumbnail) == nil)
    }

    @Test("Plex puts the inner path in url= and the token only on the outer URL")
    func plexTiers() throws {
        let art = ArtworkSource(provider: .plex, base: plexBase, token: "AAA",
                                posterPath: "/library/metadata/6/thumb/1",
                                backdropPath: "/library/metadata/6/art/1")
        let still = try #require(art.backdropURL(.still))
        let q = Dictionary(uniqueKeysWithValues:
            (URLComponents(url: still, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value) })
        #expect(q["url"] == "/library/metadata/6/art/1")
        #expect(q["width"] == "500")
        #expect(q["height"] == "282")
        #expect(q["X-Plex-Token"] == "AAA")
        // empty path → nil
        let empty = ArtworkSource(provider: .plex, base: plexBase, token: "AAA",
                                  posterPath: "", backdropPath: nil)
        #expect(empty.posterURL() == nil)
    }
}

@Suite("AetherCore — UnifiedMediaItem artwork pin")
struct UnifiedArtworkTests {
    private func item(_ source: MediaSourceID, artwork: ArtworkSource?) -> MediaItem {
        MediaItem(id: .init(source: source, rawValue: "1"), title: "T", kind: .movie,
                  posterURL: nil, backdropURL: nil, streamURL: URL(string: "https://x/s"),
                  artwork: artwork)
    }

    @Test("tier accessor mints from the pinned artwork; falls back to baked URL")
    func tierAccessor() throws {
        let art = ArtworkSource(provider: .jellyfin, base: URL(string: "https://j")!, token: "t",
                                posterPath: "/Items/1/Images/Primary", posterTag: "abc",
                                backdropPath: "/Items/1/Images/Backdrop", backdropTag: "def")
        let unified = UnifiedMediaItem(
            id: "id", title: "T", year: nil, overview: nil,
            posterURL: URL(string: "https://baked/poster"), backdropURL: URL(string: "https://baked/backdrop"),
            type: .movie, sources: [], artwork: art
        )
        // Large backdrop tier comes from the pinned source, not the baked URL.
        let large = try #require(unified.backdropURL(.backdropLarge))
        #expect(large.absoluteString.contains("fillWidth=1920"))

        // No artwork → the baked default-tier URL is returned unchanged.
        let bald = UnifiedMediaItem(
            id: "id", title: "T", year: nil, overview: nil,
            posterURL: URL(string: "https://baked/poster"), backdropURL: URL(string: "https://baked/backdrop"),
            type: .movie, sources: [], artwork: nil
        )
        #expect(bald.backdropURL(.backdropLarge) == URL(string: "https://baked/backdrop"))
    }
}

@Suite("AetherCore — DownloadJob offline poster")
struct DownloadJobPosterTests {
    private func job(posterURL: URL?, localPosterPath: String?) -> DownloadJob {
        DownloadJob(
            mediaID: .init(source: .plex(serverID: "s"), rawValue: "1"),
            title: "T", posterURL: posterURL, localPosterPath: localPosterPath,
            quality: .original
        )
    }

    @Test("no local path → displayPosterURL is the server snapshot")
    func noLocal() {
        let server = URL(string: "https://s/poster?X-Plex-Token=AAA")!
        let j = job(posterURL: server, localPosterPath: nil)
        #expect(j.localPosterURL == nil)
        #expect(j.displayPosterURL == server)
    }

    @Test("local path with no file on disk → falls back to the server URL")
    func localMissingFile() {
        let server = URL(string: "https://s/poster")!
        let j = job(posterURL: server, localPosterPath: "does-not-exist.poster")
        #expect(j.localPosterURL == nil)
        #expect(j.displayPosterURL == server)
    }

    @Test("local path with a real file → local-first")
    func localPresent() throws {
        let dir = DownloadManager.defaultDownloadsDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filename = "test-\(UUID().uuidString).poster"
        let fileURL = dir.appendingPathComponent(filename)
        try Data([0xFF, 0xD8, 0xFF]).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let j = job(posterURL: URL(string: "https://s/poster")!, localPosterPath: filename)
        #expect(j.localPosterURL == fileURL)
        #expect(j.displayPosterURL == fileURL)
    }

    @Test("withLocalPosterPath carries every other field forward")
    func copyKeepsFields() {
        let base = DownloadJob(
            mediaID: .init(source: .jellyfin(serverID: "j"), rawValue: "9"),
            title: "Show", posterURL: URL(string: "https://s/p"),
            kind: .episode, seriesTitle: "S", seasonNumber: 1, episodeNumber: 2,
            quality: .original, sourceURL: URL(string: "https://s/dl")
        )
        let copy = base.withLocalPosterPath("9.poster")
        #expect(copy.id == base.id)
        #expect(copy.sourceURL == base.sourceURL)
        #expect(copy.seriesTitle == "S")
        #expect(copy.seasonNumber == 1)
        #expect(copy.episodeNumber == 2)
        #expect(copy.localPosterPath == "9.poster")
    }
}

@Suite("AetherCore — UnifiedLibrary snapshot (#197)")
struct UnifiedLibrarySnapshotTests {
    /// A counting source so we can assert the snapshot path does *not* fan out.
    private actor CountingSource: MediaSource {
        let id: MediaSourceID
        let displayName = "Counting"
        let lib: Library
        let item: MediaItem
        private(set) var libraryCalls = 0
        init(serverID: String) {
            self.id = .plex(serverID: serverID)
            self.lib = Library(id: .init(source: .plex(serverID: serverID), rawValue: "m"), title: "Movies", kind: .movie)
            self.item = MediaItem(id: .init(source: .plex(serverID: serverID), rawValue: "1"), title: "Matrix",
                                  kind: .movie, streamURL: URL(string: "http://p/1"), guids: MediaGuids(tmdb: "603"))
        }
        func libraries() async throws -> [Library] { libraryCalls += 1; return [lib] }
        func items(in id: Library.ID) async throws -> [MediaItem] { [item] }
        func calls() -> Int { libraryCalls }
    }

    private func sampleItems() -> [UnifiedMediaItem] {
        let plex = MediaItem(id: .init(source: .plex(serverID: "s1"), rawValue: "1"), title: "Matrix",
                             kind: .movie, streamURL: URL(string: "http://p/1"), guids: MediaGuids(tmdb: "603"))
        return UnifiedLibrary.merge([plex])
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aether-snap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("snapshot persists and round-trips across store instances")
    func roundTrip() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let items = sampleItems()

        await UnifiedLibrarySnapshotStore(directory: dir)
            .save(items, for: "movie|plex.s1", at: Date(timeIntervalSince1970: 1000))

        // A fresh instance over the same directory reads it back from disk.
        let snap = try #require(
            await UnifiedLibrarySnapshotStore(directory: dir).snapshot(for: "movie|plex.s1")
        )
        #expect(snap.items.count == items.count)
        #expect(snap.items.first?.title == "Matrix")
        #expect(snap.savedAt == Date(timeIntervalSince1970: 1000))
    }

    @Test("staleness gate: <1h fresh, >=1h stale, absent stale")
    func staleness() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = UnifiedLibrarySnapshotStore(directory: dir)
        let now = Date(timeIntervalSince1970: 100_000)

        await store.save(sampleItems(), for: "k", at: now.addingTimeInterval(-30 * 60))   // 30 min
        #expect(try #require(await store.snapshot(for: "k")).age(asOf: now) < UnifiedLibrary.snapshotStaleness)

        await store.save(sampleItems(), for: "k", at: now.addingTimeInterval(-90 * 60))   // 90 min
        #expect(try #require(await store.snapshot(for: "k")).age(asOf: now) >= UnifiedLibrary.snapshotStaleness)

        #expect(await store.snapshot(for: "missing") == nil)
    }

    @Test("clearAll removes the snapshot from disk")
    func clearAll() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = UnifiedLibrarySnapshotStore(directory: dir)
        await store.save(sampleItems(), for: "k", at: Date())
        await store.clearAll()
        #expect(await store.snapshot(for: "k") == nil)
        // The file is gone, so a fresh instance sees nothing either.
        #expect(await UnifiedLibrarySnapshotStore(directory: dir).snapshot(for: "k") == nil)
    }

    @Test("a fresh snapshot is served without fanning out to sources")
    func servesSnapshotWithoutFetch() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Unique source id so the process-shared in-memory cache can't collide.
        let store = UnifiedLibrarySnapshotStore(directory: dir)
        await store.save(sampleItems(), for: "movie|plex.snaptest", at: Date())

        let src = CountingSource(serverID: "snaptest")
        let library = UnifiedLibrary(sources: [src], snapshotStore: store)
        let movies = await library.unifiedItems(kind: .movie)   // no forceRefresh

        #expect(movies.count == 1)
        #expect(movies.first?.title == "Matrix")
        #expect(await src.calls() == 0)                          // served from disk, no network
        #expect(await library.isStale(kind: .movie) == false)
    }

    @Test("a stale snapshot still serves instantly but reports stale")
    func staleSnapshotServesButFlagsRefresh() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = UnifiedLibrarySnapshotStore(directory: dir)
        await store.save(sampleItems(), for: "movie|plex.staletest",
                         at: Date().addingTimeInterval(-2 * 3600))   // 2h old

        let src = CountingSource(serverID: "staletest")
        let library = UnifiedLibrary(sources: [src], snapshotStore: store)
        let movies = await library.unifiedItems(kind: .movie)

        #expect(movies.count == 1)              // instant, from the stale snapshot
        #expect(await src.calls() == 0)         // still no blocking fetch on the read path
        #expect(await library.isStale(kind: .movie) == true)   // caller should background-refresh
    }
}
