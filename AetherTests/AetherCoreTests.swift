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

    @Test("copy() (via selecting…) preserves cast / contentRating / isFavorite")
    func copyPreservesNewFields() {
        // Regression: these three fields were added to MediaItem (Phases 2/3/4)
        // but omitted from the private copy() helper, so every Detail hydration
        // (applyingPreferences → selectingQuality → copy) silently stripped them
        // — the Cast & Crew rail, content-rating badge, and favorite heart all
        // vanished on appear.
        let item = MediaItem(
            id: .init(source: .jellyfin(serverID: "j"), rawValue: "1"),
            title: "First Man", kind: .movie,
            isFavorite: true,
            cast: [CastMember(id: "p1", name: "Ryan Gosling", role: "Neil Armstrong")],
            contentRating: "PG-13"
        )
        let copied = item.selectingQuality(.original)
        #expect(copied.cast.count == 1)
        #expect(copied.cast.first?.name == "Ryan Gosling")
        #expect(copied.contentRating == "PG-13")
        #expect(copied.isFavorite)
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

/// Minimal source with a movie library + one show whose episodes are children
/// — enough to exercise episode-level Continue Watching (#243). The mock fixture
/// can't express episode `parentID`, so this stub does.
private struct StubShowSource: MediaSource {
    let id: MediaSourceID = .mock
    let displayName = "Stub"
    let movies: [MediaItem]
    let show: MediaItem
    let episodes: [MediaItem]

    func libraries() async throws -> [Library] {
        [Library(id: .init(source: .mock, rawValue: "movies"), title: "Movies", kind: .movie),
         Library(id: .init(source: .mock, rawValue: "shows"), title: "Shows", kind: .show)]
    }
    func items(in library: Library.ID) async throws -> [MediaItem] {
        library.rawValue == "movies" ? movies : [show]
    }
    func children(of id: MediaID) async throws -> [MediaItem] {
        id == show.id ? episodes : []
    }
    func item(for id: MediaID) async throws -> MediaItem? {
        ([show] + movies + episodes).first { $0.id == id }
    }
}

@Suite("AetherCore — HomeFeedBuilder")
struct HomeFeedBuilderTests {

    @Test("Continue Watching surfaces a show's in-progress episode — one per show, mixed with movies by recency (#243)")
    func continueWatchingIncludesEpisodes() async throws {
        let movieID = MediaID(source: .mock, rawValue: "a")
        let showID = MediaID(source: .mock, rawValue: "show:S")
        let e1 = MediaID(source: .mock, rawValue: "S1E1")
        let e2 = MediaID(source: .mock, rawValue: "S1E2")
        let movie = MediaItem(id: movieID, title: "A Movie", kind: .movie, runtime: .seconds(3600))
        let show = MediaItem(id: showID, title: "The Show", kind: .show)
        let ep1 = MediaItem(id: e1, title: "Episode 1", kind: .episode,
                            seriesTitle: "The Show", seasonNumber: 1, episodeNumber: 1, parentID: showID)
        let ep2 = MediaItem(id: e2, title: "Episode 2", kind: .episode,
                            seriesTitle: "The Show", seasonNumber: 1, episodeNumber: 2, parentID: showID)
        let source = StubShowSource(movies: [movie], show: show, episodes: [ep1, ep2])

        let store = ResumeStore()
        let now = Date()
        await store.record(.init(mediaID: movieID, position: .seconds(60), updatedAt: now.addingTimeInterval(-300)))
        await store.record(.init(mediaID: e1, position: .seconds(60), updatedAt: now.addingTimeInterval(-600)))
        await store.record(.init(mediaID: e2, position: .seconds(60), updatedAt: now.addingTimeInterval(-100)))

        let feed = try await HomeFeedBuilder().build(source: source, resumeStore: store)

        // The show contributes exactly one entry — its most-recent episode (e2) —
        // ordered with the movie by recency; the older episode is not surfaced.
        #expect(feed.continueWatching.map(\.item.id) == [e2, movieID])
        #expect(feed.continueWatching.first?.item.kind == .episode)
        #expect(feed.continueWatching.contains { $0.item.id == e1 } == false)
    }

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

    @Test("a show container is switchable on every source that has it (#194)")
    func showContainerPlayableAcrossSources() {
        func show(_ source: MediaSourceID, _ id: String) -> MediaItem {
            MediaItem(id: .init(source: source, rawValue: id), title: "Severance",
                      kind: .show, guids: MediaGuids(tvdb: "371980"))
        }
        let u = UnifiedLibrary.merge([show(.plex(serverID: "s1"), "1"),
                                      show(.jellyfin(serverID: "j1"), "9")])
        #expect(u.count == 1)
        #expect(u[0].sources.count == 2)
        // Both switchable even though a series container has no streamURL — the
        // bug was both showing as "Unavailable".
        let allPlayable = u[0].sources.allSatisfy(\.playable)
        #expect(allPlayable)
        #expect(u[0].preferredSource != nil)
    }

    @Test("a movie with no resolvable stream is still unavailable (leaf gating intact)")
    func movieWithoutStreamUnavailable() {
        let u = UnifiedLibrary.merge([plex("1", "Matrix", tmdb: "603", stream: false)])
        #expect(u.count == 1)
        #expect(u[0].sources.first?.playable == false)
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

    @Test("Continue Watching surfaces an in-progress episode — one per show across seasons (#263)")
    func continueWatchingEpisodes() async {
        let showID = MediaID(source: .mock, rawValue: "show:S")
        let e1 = MediaID(source: .mock, rawValue: "S1E1")
        let e2 = MediaID(source: .mock, rawValue: "S2E3")
        let show = MediaItem(id: showID, title: "The Show", kind: .show)
        // parentID resolves to the *season* on real sources (Plex/Jellyfin), so
        // the two episodes carry *different* parentIDs — grouping must collapse
        // them to one show via seriesTitle, not split them per season.
        let ep1 = MediaItem(id: e1, title: "Episode 1", kind: .episode,
                            seriesTitle: "The Show", seasonNumber: 1, episodeNumber: 1,
                            parentID: .init(source: .mock, rawValue: "season:1"))
        let ep2 = MediaItem(id: e2, title: "Episode 3", kind: .episode,
                            seriesTitle: "The Show", seasonNumber: 2, episodeNumber: 3,
                            parentID: .init(source: .mock, rawValue: "season:2"))
        let source = StubShowSource(movies: [], show: show, episodes: [ep1, ep2])

        let store = ResumeStore()
        let now = Date()
        await store.record(.init(mediaID: e1, position: .seconds(60), updatedAt: now.addingTimeInterval(-600)))
        await store.record(.init(mediaID: e2, position: .seconds(60), updatedAt: now.addingTimeInterval(-100)))

        let rails = await UnifiedLibrary(sources: [source]).homeRails(resumeStore: store, forceRefresh: true)

        // The show contributes exactly one entry — its most-recently-watched
        // episode (e2), even though e1 is a different season. Before #263 the
        // unified Home surfaced no in-progress episode at all (it only matched
        // resume points against top-level movies and show containers).
        #expect(rails.continueWatching.map(\.item.id) == [e2])
        #expect(rails.continueWatching.first?.item.kind == .episode)
        #expect(rails.continueWatching.contains { $0.item.id == e1 } == false)
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

    @Test("Plex logoURL serves the RAW path + token — never the JPEG transcoder (alpha) (#273)")
    func plexLogoURL() throws {
        let art = ArtworkSource(provider: .plex, base: plexBase, token: "AAA",
                                posterPath: "/library/metadata/6/thumb/1", backdropPath: nil,
                                logoPath: "/library/metadata/6/clearLogo/99")
        let url = try #require(art.logoURL())
        #expect(!url.path.contains("/photo/:/transcode"))
        #expect(url.path.hasSuffix("/library/metadata/6/clearLogo/99"))
        let q = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
        #expect(q == [URLQueryItem(name: "X-Plex-Token", value: "AAA")])
        // No logo path → nil.
        let none = ArtworkSource(provider: .plex, base: plexBase, token: "AAA",
                                 posterPath: nil, backdropPath: nil)
        #expect(none.logoURL() == nil)
    }

    @Test("Jellyfin logoURL uses aspect-fit maxWidth + Webp; requires the tag (#273)")
    func jellyfinLogoURL() throws {
        let art = ArtworkSource(provider: .jellyfin, base: jellyBase, token: "tok",
                                posterPath: nil, backdropPath: nil,
                                logoPath: "/Items/9/Images/Logo", logoTag: "lll")
        let url = try #require(art.logoURL())
        let q = Dictionary(uniqueKeysWithValues:
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value) })
        #expect(q["maxWidth"] == "800")
        #expect(q["fillWidth"] == nil)         // fill would crop the logo's aspect
        #expect(q["fillHeight"] == nil)
        #expect(q["format"] == "Webp")
        #expect(q["tag"] == "lll")
        #expect(q["api_key"] == "tok")
        // Logo path without a tag → nil (nothing to address).
        let noTag = ArtworkSource(provider: .jellyfin, base: jellyBase, token: "tok",
                                  posterPath: nil, backdropPath: nil,
                                  logoPath: "/Items/9/Images/Logo")
        #expect(noTag.logoURL() == nil)
    }

    @Test("legacy ArtworkSource JSON (no logo keys) still decodes — snapshot back-compat (#273)")
    func legacyDecodeBackCompat() throws {
        // Encoded by a build BEFORE logoPath/logoTag existed; a throwing decode
        // here would silently wipe the persisted catalog snapshot.
        let old = ArtworkSource(provider: .plex, base: plexBase, token: "AAA",
                                posterPath: "/p", backdropPath: "/b")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        json.removeValue(forKey: "logoPath")
        json.removeValue(forKey: "logoTag")
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(ArtworkSource.self, from: data)
        #expect(decoded.logoPath == nil)
        #expect(decoded.logoURL() == nil)
        #expect(decoded.posterPath == "/p")
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

    /// A source whose movie library is momentarily empty on the first fetch and
    /// populated thereafter — models a server not-yet-ready at launch / a hiccup.
    private actor FlakyMovieSource: MediaSource {
        nonisolated let id: MediaSourceID
        nonisolated let displayName = "Flaky"
        private let lib: Library
        private let movie: MediaItem
        private var calls = 0
        init(serverID: String) {
            self.id = .plex(serverID: serverID)
            self.lib = Library(id: .init(source: .plex(serverID: serverID), rawValue: "m"), title: "Movies", kind: .movie)
            self.movie = MediaItem(id: .init(source: .plex(serverID: serverID), rawValue: "1"), title: "Matrix",
                                   kind: .movie, streamURL: URL(string: "http://p/1"), guids: MediaGuids(tmdb: "603"))
        }
        func libraries() async throws -> [Library] { [lib] }
        func items(in id: Library.ID) async throws -> [MediaItem] {
            calls += 1
            return calls == 1 ? [] : [movie]   // empty once, then recovered
        }
    }

    @Test("a transient empty fan-out is not pinned — the next read self-heals (#263)")
    func emptyResultNotPinned() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Unique source id so the process-shared in-memory cache can't collide.
        let source = FlakyMovieSource(serverID: "regr263")
        let library = UnifiedLibrary(sources: [source], snapshotStore: UnifiedLibrarySnapshotStore(directory: dir))

        // First fetch sees an empty movie library (source momentarily not ready).
        let first = await library.unifiedItems(kind: .movie)
        #expect(first.isEmpty)

        // Second fetch (NO forceRefresh): because the empty was never cached or
        // snapshotted, this fans out again and now sees the recovered catalog —
        // instead of being stranded on the pinned empty. This is the #263 fix.
        let second = await library.unifiedItems(kind: .movie)
        #expect(second.count == 1)
        #expect(second.first?.title == "Matrix")
    }
}

@Suite("AetherCore — MediaSourceID .local (#207)")
struct MediaSourceIDLocalTests {
    @Test("stableKey + Codable round-trip for .local")
    func localRoundTrips() throws {
        #expect(MediaSourceID.local.stableKey == "local")
        let data = try JSONEncoder().encode(MediaSourceID.local)
        #expect(try JSONDecoder().decode(MediaSourceID.self, from: data) == .local)
    }

    @Test("existing source ids still round-trip unchanged")
    func othersRoundTrip() throws {
        for id in [MediaSourceID.mock, .plex(serverID: "s1"), .jellyfin(serverID: "j1"), .synology(host: "h")] {
            let data = try JSONEncoder().encode(id)
            #expect(try JSONDecoder().decode(MediaSourceID.self, from: data) == id)
        }
    }

    @Test(".local maps to the Local streaming kind (#208), lowest priority")
    func localStreamingKind() {
        #expect(MediaSourceKind(streaming: .local) == .local)
        #expect(MediaSourceKind.local > .jellyfin)   // servers preferred over local
    }
}

@Suite("AetherCore — TitleInference (#206)")
struct TitleInferenceTests {
    @Test("movies: title + year, junk stripped")
    func movies() {
        let cases: [(String, String, Int?)] = [
            ("Movie Name (2019) 1080p.mkv", "Movie Name", 2019),
            ("Movie.Name.2019.x265.mkv", "Movie Name", 2019),
            ("Blade Runner 2049 (2017) 2160p BluRay x265.mkv", "Blade Runner 2049", 2017),
            ("The.Matrix.1999.1080p.BluRay.x264-GROUP.mkv", "The Matrix", 1999),
            ("Parasite (2019) [1080p] [WEBRip].mp4", "Parasite", 2019),
            ("Inception.mkv", "Inception", nil),
        ]
        for (file, title, year) in cases {
            let t = TitleInference(filename: file)
            #expect(t.title == title, "title for \(file): got \(t.title)")
            #expect(t.year == year, "year for \(file): got \(String(describing: t.year))")
            #expect(t.kind == .movie)
        }
    }

    @Test("episodes: season + episode + show title")
    func episodes() {
        let cases: [(String, String, Int, Int)] = [
            ("Show.Name.S01E02.mkv", "Show Name", 1, 2),
            ("Show Name - 1x02 - Title.mkv", "Show Name", 1, 2),
            ("Breaking.Bad.S05E14.1080p.x265.mkv", "Breaking Bad", 5, 14),
            ("Severance S01E09 720p.mkv", "Severance", 1, 9),
            ("The Wire S1E1.mp4", "The Wire", 1, 1),
        ]
        for (file, title, season, episode) in cases {
            let t = TitleInference(filename: file)
            #expect(t.title == title, "title for \(file): got \(t.title)")
            #expect(t.season == season, "season for \(file): got \(String(describing: t.season))")
            #expect(t.episode == episode, "episode for \(file): got \(String(describing: t.episode))")
            #expect(t.kind == .episode)
            #expect(t.isEpisode)
        }
    }

    @Test("season folder + bare episode number → uses folder season")
    func seasonFolder() {
        let t = TitleInference(filename: "E04 - Some Title.mkv",
                               pathComponents: ["Breaking Bad", "Season 03"])
        #expect(t.season == 3)
        #expect(t.episode == 4)
        #expect(t.kind == .episode)
    }

    @Test("resolution 1920x1080 is not mistaken for an episode marker")
    func resolutionNotEpisode() {
        let t = TitleInference(filename: "Some Movie 2018 1920x1080 x264.mkv")
        #expect(t.title == "Some Movie")
        #expect(t.year == 2018)
        #expect(t.season == nil)
        #expect(t.episode == nil)
    }

    @Test("title falls back to the show folder when the filename is just a number")
    func folderFallback() {
        let t = TitleInference(filename: "04.mkv", pathComponents: ["The Office", "Season 02"])
        #expect(t.season == 2)
        #expect(t.episode == 4)
        #expect(t.title == "The Office")
    }
}

@Suite("AetherCore — Local Library (#208)")
struct LocalLibraryTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aether-local-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func sourceFile(_ name: String) throws -> URL {
        // Unique *directory*, clean filename — so lastPathComponent (what
        // inference reads) matches a real import, not a UUID-prefixed temp name.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data("video-bytes".utf8).write(to: url)
        return url
    }

    @Test("import copies the file, infers metadata, persists across instances")
    func importPersists() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = try sourceFile("Inception (2010) 1080p.mp4")
        defer { try? FileManager.default.removeItem(at: src) }

        let store = LocalLibraryStore(directory: dir)
        let item = try await store.importFile(at: src)
        #expect(item.title == "Inception")
        #expect(item.year == 2010)
        #expect(!item.isEpisode)
        #expect(FileManager.default.fileExists(atPath: store.fileURL(for: item).path))

        // A fresh instance over the same directory reads the persisted index.
        let reopened = LocalLibraryStore(directory: dir)
        let all = await reopened.allItems()
        #expect(all.count == 1)
        #expect(all.first?.title == "Inception")
    }

    @Test("a movie import surfaces as a flat, playable movie")
    func movieMapping() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = try sourceFile("Inception (2010).mp4"); defer { try? FileManager.default.removeItem(at: src) }
        let store = LocalLibraryStore(directory: dir)
        _ = try await store.importFile(at: src)
        let source = LocalMediaSource(store: store)

        #expect(source.id == .local)
        let libs = try await source.libraries()
        let movieLib = try #require(libs.first { $0.kind == .movie })
        #expect(libs.contains { $0.kind == .show } == false)   // no episodes → no TV library
        let items = try await source.items(in: movieLib.id)
        #expect(items.count == 1)
        #expect(items[0].title == "Inception")
        #expect(items[0].kind == .movie)
        #expect(items[0].streamURL != nil)
    }

    @Test("episodes group into a show container with playable children")
    func episodeGrouping() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let e1 = try sourceFile("Severance.S01E01.mkv")
        let e2 = try sourceFile("Severance.S01E02.mkv")
        let movie = try sourceFile("Dune (2021).mp4")
        defer { [e1, e2, movie].forEach { try? FileManager.default.removeItem(at: $0) } }

        let store = LocalLibraryStore(directory: dir)
        for f in [e1, e2, movie] { _ = try await store.importFile(at: f) }
        let source = LocalMediaSource(store: store)

        let libs = try await source.libraries()
        #expect(libs.contains { $0.kind == .movie })
        let showLib = try #require(libs.first { $0.kind == .show })

        let shows = try await source.items(in: showLib.id)
        #expect(shows.count == 1)                       // one container for "Severance"
        let show = shows[0]
        #expect(show.kind == .show)
        #expect(show.title == "Severance")
        #expect(show.episodeCount == 2)
        #expect(show.streamURL == nil)                  // containers aren't directly playable

        let episodes = try await source.children(of: show.id)
        #expect(episodes.count == 2)
        #expect(episodes[0].episodeNumber == 1)         // sorted by season/episode
        #expect(episodes[1].episodeNumber == 2)
        #expect(episodes.allSatisfy { $0.streamURL != nil && $0.kind == .episode })
        #expect(episodes[0].seriesTitle == "Severance")
    }

    @Test("remove deletes the item and its file")
    func remove() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = try sourceFile("Movie.2020.mkv")
        defer { try? FileManager.default.removeItem(at: src) }

        let store = LocalLibraryStore(directory: dir)
        let item = try await store.importFile(at: src)
        let path = store.fileURL(for: item).path
        #expect(FileManager.default.fileExists(atPath: path))
        await store.remove(item.id)
        #expect(await store.count() == 0)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    // MARK: - Manual overrides (#211)

    @Test("manual overrides win over the TMDb match + inference, and persist")
    func overridesWin() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = try sourceFile("Whatever (1999).mp4"); defer { try? FileManager.default.removeItem(at: src) }
        let store = LocalLibraryStore(directory: dir)
        let item = try await store.importFile(at: src)
        // A wrong auto-match…
        await store.setMatch(TMDbMetadata(tmdbID: 1, title: "Wrong Movie", year: 2001,
            overview: "nope", posterURL: nil, backdropURL: nil), for: item.id)
        // …corrected by the user.
        await store.setOverrides(.init(title: "The Matrix", year: 1999, overview: "Neo."), for: item.id)

        // Survives relaunch.
        let reopened = LocalLibraryStore(directory: dir)
        let stored = try #require(await reopened.allItems().first)
        #expect(stored.effectiveTitle == "The Matrix")
        #expect(stored.effectiveYear == 1999)
        #expect(stored.effectiveOverview == "Neo.")
        let source = LocalMediaSource(store: reopened)
        let lib = try #require(try await source.libraries().first { $0.kind == .movie })
        #expect(try await source.items(in: lib.id).first?.title == "The Matrix")
    }

    @Test("overriding isEpisode reclassifies a movie into the TV library")
    func reclassify() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = try sourceFile("Pilot (2020).mp4"); defer { try? FileManager.default.removeItem(at: src) }
        let store = LocalLibraryStore(directory: dir)
        let item = try await store.importFile(at: src)
        let source = LocalMediaSource(store: store)
        #expect(try await source.libraries().contains { $0.kind == .show } == false)

        await store.setOverrides(.init(title: "My Show", isEpisode: true, season: 1, episode: 1), for: item.id)
        let libs = try await source.libraries()
        #expect(libs.contains { $0.kind == .show })
        #expect(libs.contains { $0.kind == .movie } == false)
        let showLib = try #require(libs.first { $0.kind == .show })
        let shows = try await source.items(in: showLib.id)
        #expect(shows.first?.title == "My Show")
        #expect(try await source.children(of: shows[0].id).first?.episodeNumber == 1)
    }

    @Test("custom artwork is stored, used as the poster, and removed with the item")
    func customArtwork() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = try sourceFile("Movie (2000).mp4"); defer { try? FileManager.default.removeItem(at: src) }
        let store = LocalLibraryStore(directory: dir)
        let item = try await store.importFile(at: src)

        #expect(await store.setArtwork(Data("png-bytes".utf8), for: item.id) != nil)
        let stored = try #require(await store.allItems().first)
        let artURL = try #require(store.artworkURL(for: stored))
        #expect(FileManager.default.fileExists(atPath: artURL.path))

        let source = LocalMediaSource(store: store)
        let lib = try #require(try await source.libraries().first { $0.kind == .movie })
        #expect(try await source.items(in: lib.id).first?.posterURL == artURL)

        await store.remove(item.id)
        #expect(!FileManager.default.fileExists(atPath: artURL.path))
    }

    @Test("clearing overrides reverts to inference")
    func clearOverrides() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = try sourceFile("Real Title (2012).mp4"); defer { try? FileManager.default.removeItem(at: src) }
        let store = LocalLibraryStore(directory: dir)
        let item = try await store.importFile(at: src)
        await store.setOverrides(.init(title: "Temp"), for: item.id)
        #expect(await store.allItems().first?.effectiveTitle == "Temp")
        await store.setOverrides(nil, for: item.id)
        let stored = try #require(await store.allItems().first)
        #expect(stored.overrides == nil)
        #expect(stored.effectiveTitle == "Real Title")
    }

    @Test("custom poster is versioned; replacing deletes the old file, reset deletes the current (#211)")
    func artworkVersioningAndCleanup() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = try sourceFile("Film (2001).mp4"); defer { try? FileManager.default.removeItem(at: src) }
        let store = LocalLibraryStore(directory: dir)
        let item = try await store.importFile(at: src)

        let name1 = try #require(await store.setArtwork(Data("a".utf8), for: item.id))
        let name2 = try #require(await store.setArtwork(Data("b".utf8), for: item.id))
        #expect(name1 != name2)   // versioned → URL changes so image caches repaint
        let artworkDir = dir.appendingPathComponent("Artwork")
        #expect(!FileManager.default.fileExists(atPath: artworkDir.appendingPathComponent(name1).path)) // old gone
        let storedAfter = try #require(await store.allItems().first)
        let current = try #require(store.artworkURL(for: storedAfter))
        #expect(FileManager.default.fileExists(atPath: current.path))                                  // new kept

        await store.setOverrides(nil, for: item.id)   // reset
        #expect(!FileManager.default.fileExists(atPath: current.path))                                 // poster cleaned up
    }
}

@Suite("AetherCore — PlaybackEngine (mkv #173)")
struct PlaybackEngineTests {
    private func eng(_ s: String) -> PlaybackEngine { .engine(for: URL(string: s)!) }

    @Test("system for AVPlayer containers + HLS; VLC for mkv/avi/ts/webm")
    func selection() {
        #expect(eng("file:///x/Movie.mp4") == .system)
        #expect(eng("file:///x/Movie.m4v") == .system)
        #expect(eng("file:///x/Clip.mov") == .system)
        #expect(eng("https://h/video/start.m3u8?session=1") == .system)
        #expect(eng("file:///x/Movie.mkv") == .vlc)
        #expect(eng("file:///x/Movie.avi") == .vlc)
        #expect(eng("file:///x/Movie.ts") == .vlc)
        #expect(eng("file:///x/Movie.webm") == .vlc)
    }

    @Test("no stream URL → system")
    func noURL() {
        let item = MediaItem(id: .init(source: .local, rawValue: "1"), title: "X", kind: .movie)
        #expect(PlaybackEngine.engine(for: item) == .system)
    }
}

@Suite("AetherCore — TMDbClient (#210)")
struct TMDbClientTests {
    private struct StubAPI: APIClient {
        let json: String
        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            (Data(json.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test("matches a movie → id / title / year / overview / poster URL")
    func matchMovie() async {
        let json = #"""
        {"results":[{"id":27205,"title":"Inception","release_date":"2010-07-15",
          "overview":"A thief who steals secrets.","poster_path":"/abc.jpg","backdrop_path":"/bd.jpg"}]}
        """#
        let m = await TMDbClient(apiKey: "k", api: StubAPI(json: json))
            .match(title: "Inception", year: 2010, isEpisode: false)
        #expect(m?.tmdbID == 27205)
        #expect(m?.title == "Inception")
        #expect(m?.year == 2010)
        #expect(m?.overview == "A thief who steals secrets.")
        #expect(m?.posterURL?.absoluteString == "https://image.tmdb.org/t/p/w500/abc.jpg")
        #expect(m?.backdropURL?.absoluteString == "https://image.tmdb.org/t/p/w1280/bd.jpg")
    }

    @Test("matches a TV show via name / first_air_date")
    func matchTV() async {
        let json = #"""
        {"results":[{"id":95396,"name":"Severance","first_air_date":"2022-02-18","overview":"Mark."}]}
        """#
        let m = await TMDbClient(apiKey: "k", api: StubAPI(json: json))
            .match(title: "Severance", year: nil, isEpisode: true)
        #expect(m?.tmdbID == 95396)
        #expect(m?.title == "Severance")
        #expect(m?.year == 2022)
        #expect(m?.posterURL == nil)   // no poster_path in this result
    }

    @Test("empty key disables matching")
    func emptyKey() async {
        let client = TMDbClient(apiKey: "  ", api: StubAPI(json: #"{"results":[]}"#))
        #expect(client.isConfigured == false)
        #expect(await client.match(title: "X", year: nil, isEpisode: false) == nil)
    }

    @Test("searchCandidates returns multiple results, most-relevant first, capped by limit (#211)")
    func candidates() async {
        let json = #"""
        {"results":[
          {"id":1,"title":"A","release_date":"2001-01-01"},
          {"id":2,"title":"B","release_date":"2002-01-01"},
          {"id":3,"title":"C"}
        ]}
        """#
        let cands = await TMDbClient(apiKey: "k", api: StubAPI(json: json))
            .searchCandidates(title: "x", year: nil, isEpisode: false, limit: 2)
        #expect(cands.count == 2)
        #expect(cands[0].tmdbID == 1)
        #expect(cands[1].title == "B")
    }

    @Test("no results → nil")
    func noResults() async {
        let m = await TMDbClient(apiKey: "k", api: StubAPI(json: #"{"results":[]}"#))
            .match(title: "Nope", year: nil, isEpisode: false)
        #expect(m == nil)
    }
}

@Suite("AetherCore — DetailFormatting (#241)")
struct DetailFormattingTests {
    @Test("kind labels")
    func kindLabels() {
        #expect(DetailFormatting.kindLabel(.movie) == "Movie")
        #expect(DetailFormatting.kindLabel(.episode) == "Episode")
        #expect(DetailFormatting.kindLabel(.show) == "Series")
        #expect(DetailFormatting.kindLabel(.season) == "Season")
    }

    @Test("runtime / position formatting")
    func durations() {
        #expect(DetailFormatting.runtime(.seconds(3661)) == "1h 1m")
        #expect(DetailFormatting.runtime(.seconds(125)) == "2m")
        #expect(DetailFormatting.position(.seconds(3661)) == "01:01:01")
        #expect(DetailFormatting.position(.seconds(125)) == "02:05")
    }

    @Test("percent / bitrate / channels")
    func numbers() {
        #expect(DetailFormatting.percent(0.426) == "43%")
        #expect(DetailFormatting.bitrate(8000) == "8.0 Mbps")
        #expect(DetailFormatting.bitrate(800) == "800 kbps")
        #expect(DetailFormatting.channelLabel(1) == "Mono")
        #expect(DetailFormatting.channelLabel(2) == "2.0")
        #expect(DetailFormatting.channelLabel(6) == "5.1")
        #expect(DetailFormatting.channelLabel(8) == "7.1")
        #expect(DetailFormatting.channelLabel(3) == "3 ch")
    }

    @Test("video / audio / HDR lines from MediaInfo")
    func mediaLines() {
        let full = MediaInfo(videoCodec: "hevc", audioCodec: "eac3", audioChannels: 6,
                             videoResolution: "4K", isHDR: true, isDolbyVision: true)
        #expect(DetailFormatting.videoLine(full) == "HEVC 4K")
        #expect(DetailFormatting.audioLine(full) == "EAC3 5.1")
        #expect(DetailFormatting.hdrBadge(full) == "Dolby Vision")
        #expect(DetailFormatting.hdrBadge(MediaInfo(isHDR: true)) == "HDR")
        #expect(DetailFormatting.hdrBadge(MediaInfo()) == nil)
        #expect(DetailFormatting.videoLine(nil) == nil)
        #expect(DetailFormatting.videoLine(MediaInfo(videoCodec: "h264")) == "H264")
        #expect(DetailFormatting.audioLine(MediaInfo()) == nil)
    }

    @Test("season / episode labels")
    func labels() {
        // Generic "Season N" titles stay as "Season N".
        let generic = MediaItem(id: .init(source: .mock, rawValue: "s2"), title: "Season 2",
                                kind: .season, seasonNumber: 2)
        #expect(DetailFormatting.seasonLabel(generic) == "Season 2")
        // No real title at all → derive from the number.
        let numbered = MediaItem(id: .init(source: .mock, rawValue: "s2b"), title: "",
                                 kind: .season, seasonNumber: 2)
        #expect(DetailFormatting.seasonLabel(numbered) == "Season 2")
        // A real, human season name is surfaced alongside the number (#263).
        let named = MediaItem(id: .init(source: .mock, rawValue: "s2n"), title: "Asylum",
                              kind: .season, seasonNumber: 2)
        #expect(DetailFormatting.seasonLabel(named) == "S2 · Asylum")
        // Localized generic titles are generic too — a Czech-localized Plex
        // sends "7. řada" / "Řada 7" / "Série 1", none of which are names.
        for czechTitle in ["7. řada", "Řada 7", "Série 7", "7. série", "Sezóna 7"] {
            let czech = MediaItem(id: .init(source: .mock, rawValue: "cz-\(czechTitle)"),
                                  title: czechTitle, kind: .season, seasonNumber: 7)
            #expect(DetailFormatting.seasonLabel(czech) == "Season 7", "\(czechTitle)")
        }
        // A season titled with the *series* name (some agents do this) is not a
        // real season name → fall back to the number.
        let seriesNamed = MediaItem(id: .init(source: .mock, rawValue: "s3"), title: "The Show",
                                    kind: .season, seriesTitle: "The Show", seasonNumber: 3)
        #expect(DetailFormatting.seasonLabel(seriesNamed) == "Season 3")
        // Named season with no number keeps its name as-is.
        let specials = MediaItem(id: .init(source: .mock, rawValue: "sx"), title: "Specials", kind: .season)
        #expect(DetailFormatting.seasonLabel(specials) == "Specials")
        // No name and no number → the bare word.
        let bare = MediaItem(id: .init(source: .mock, rawValue: "sb"), title: "Season", kind: .season)
        #expect(DetailFormatting.seasonLabel(bare) == "Season")
        let ep = MediaItem(id: .init(source: .mock, rawValue: "e"), title: "Pilot",
                           kind: .episode, seasonNumber: 1, episodeNumber: 3)
        #expect(DetailFormatting.episodeLabel(ep) == "S1E3 · Pilot")
        // Hero episode-context line (#266 Detail Phase 1) — spaced, dash before title.
        #expect(DetailFormatting.episodeContext(ep) == "S1 • E3 - Pilot")
        let noNumbers = MediaItem(id: .init(source: .mock, rawValue: "e2"), title: "Special", kind: .episode)
        #expect(DetailFormatting.episodeContext(noNumbers) == "Special")
    }

    @Test("air date — fixed en-US month-day-year (#266)")
    func airDate() {
        // 2007-07-26 UTC.
        let date = Date(timeIntervalSince1970: 1_185_408_000)
        #expect(DetailFormatting.airDate(date) == "Jul 26, 2007")
    }
}

@Suite("AetherCore — OnDeck (#260)")
struct OnDeckTests {
    private func ep(_ s: Int, _ e: Int, watched: Bool = false) -> MediaItem {
        MediaItem(id: .init(source: .mock, rawValue: "s\(s)e\(e)"), title: "E\(s)x\(e)",
                  kind: .episode, seasonNumber: s, episodeNumber: e, isWatched: watched)
    }

    @Test("most-recent in-progress wins over an earlier unwatched season (the S3-vs-S7 bug)")
    func inProgressWins() {
        let s7 = ep(7, 2)
        let episodes = [ep(1, 1, watched: true), ep(3, 5), s7, ep(7, 3)]
        let now = Date()
        let next = OnDeck.next(episodes: episodes) { $0.id == s7.id ? now : nil }
        #expect(next?.id == s7.id)
    }

    @Test("no in-progress → the episode after the last one watched")
    func afterLastWatched() {
        let episodes = [ep(1, 1, watched: true), ep(1, 2, watched: true), ep(1, 3), ep(2, 1)]
        let next = OnDeck.next(episodes: episodes) { _ in nil }
        #expect(next?.seasonNumber == 1 && next?.episodeNumber == 3)
    }

    @Test("nothing watched → the first episode (in order)")
    func nothingWatched() {
        let next = OnDeck.next(episodes: [ep(2, 1), ep(1, 1), ep(1, 2)]) { _ in nil }
        #expect(next?.seasonNumber == 1 && next?.episodeNumber == 1)
    }

    @Test("all watched → nil")
    func allWatched() {
        #expect(OnDeck.next(episodes: [ep(1, 1, watched: true), ep(1, 2, watched: true)]) { _ in nil } == nil)
    }

    @Test("among several in-progress, the most recent wins")
    func mostRecentInProgress() {
        let older = ep(1, 4); let newer = ep(2, 1)
        let base = Date()
        let next = OnDeck.next(episodes: [older, newer]) {
            $0.id == older.id ? base : ($0.id == newer.id ? base.addingTimeInterval(100) : nil)
        }
        #expect(next?.id == newer.id)
    }
}

@Suite("AetherCore — MediaSelectionMatcher (#68)")
struct MediaSelectionMatcherTests {

    @Test("language normalization bridges ISO 639-2 and BCP-47")
    func languageNormalization() {
        #expect(MediaSelectionMatcher.normalizedLanguage("cze") == "cs")
        #expect(MediaSelectionMatcher.normalizedLanguage("ces") == "cs")
        #expect(MediaSelectionMatcher.normalizedLanguage("cs-CZ") == "cs")
        #expect(MediaSelectionMatcher.normalizedLanguage("eng") == "en")
        #expect(MediaSelectionMatcher.normalizedLanguage("en-US") == "en")
        #expect(MediaSelectionMatcher.normalizedLanguage("") == nil)
    }

    @Test("picks the option matching the selected track's language")
    func languageMatch() {
        let options: [(language: String?, name: String)] = [
            (language: "en", name: "English"),
            (language: "cs", name: "Čeština"),
        ]
        // Source gives ISO 639-2 "cze"; AVFoundation exposes BCP-47 "cs".
        #expect(MediaSelectionMatcher.bestIndex(language: "cze", title: "Czech 5.1", among: options) == 1)
        #expect(MediaSelectionMatcher.bestIndex(language: "eng", title: nil, among: options) == 0)
    }

    @Test("title tie-breaks multiple tracks of the same language")
    func titleTieBreak() {
        let options: [(language: String?, name: String)] = [
            (language: "en", name: "English Stereo"),
            (language: "en", name: "English 5.1 Surround"),
        ]
        #expect(MediaSelectionMatcher.bestIndex(language: "en", title: "English 5.1", among: options) == 1)
        // No usable title → first language match.
        #expect(MediaSelectionMatcher.bestIndex(language: "en", title: "Director Commentary", among: options) == 0)
    }

    @Test("no confident match → nil (leave the player default alone)")
    func noMatch() {
        let options: [(language: String?, name: String)] = [(language: "ja", name: "日本語")]
        #expect(MediaSelectionMatcher.bestIndex(language: "cs", title: "Czech", among: options) == nil)
        #expect(MediaSelectionMatcher.bestIndex(language: nil, title: nil, among: options) == nil)
        // Exact title match works even without a language.
        #expect(MediaSelectionMatcher.bestIndex(language: nil, title: "日本語", among: options) == 0)
    }
}

@Suite("AetherCore — PlaybackRequest explicit selection (#68)")
struct PlaybackRequestSelectionTests {
    private func item(audioSelected: String? = nil, subtitleSelected: String?? = .none) -> MediaItem {
        var item = MediaItem(
            id: .init(source: .mock, rawValue: "x"), title: "X", kind: .movie,
            streamURL: URL(string: "https://s/x.mp4"),
            audioTracks: [
                .init(id: "a1", title: "English", languageCode: "eng", isSelected: true),
                .init(id: "a2", title: "Czech", languageCode: "cze"),
            ],
            subtitleTracks: [
                .init(id: "s1", title: "English", languageCode: "eng", isSelected: true),
                .init(id: "s2", title: "Czech", languageCode: "cze"),
            ]
        )
        if let audioSelected {
            if let track = item.audioTracks.first(where: { $0.id == audioSelected }) {
                item = item.selectingAudioTrack(track)
            }
        }
        if case let .some(value) = subtitleSelected {
            let track = value.flatMap { id in item.subtitleTracks.first(where: { $0.id == id }) }
            item = item.selectingSubtitleTrack(track)
        }
        return item
    }

    @Test("source defaults → not explicit (direct play stays cheap)")
    func defaultsNotExplicit() {
        let request = PlaybackRequest(item: item(), startTime: nil)
        #expect(request.hasExplicitTrackSelection == false)
    }

    @Test("picking a different audio track → explicit")
    func audioPickExplicit() {
        let request = PlaybackRequest(item: item(audioSelected: "a2"), startTime: nil)
        #expect(request.hasExplicitTrackSelection == true)
    }

    @Test("subtitles Off (with a flagged default) → explicit")
    func subtitleOffExplicit() {
        let request = PlaybackRequest(item: item(subtitleSelected: .some(nil)), startTime: nil)
        #expect(request.hasExplicitTrackSelection == true)
        #expect(request.subtitleStreamID == "0")
    }
}

@Suite("AetherCore — playback preference application (#68)")
@MainActor
struct PlaybackPreferenceApplicationTests {
    private func episode(_ id: String) -> MediaItem {
        MediaItem(
            id: .init(source: .mock, rawValue: id), title: id, kind: .episode,
            streamURL: URL(string: "https://s/\(id).mp4"),
            audioTracks: [
                .init(id: "\(id)-en", title: "English", languageCode: "eng", isSelected: true),
                .init(id: "\(id)-cs", title: "Czech", languageCode: "cze"),
            ],
            subtitleTracks: [
                .init(id: "\(id)-sub-en", title: "English", languageCode: "eng", isSelected: true),
                .init(id: "\(id)-sub-cs", title: "Czech", languageCode: "cze"),
            ]
        )
    }

    @Test("next episode inherits the session's audio language and subtitle Off")
    func nextEpisodeCarriesSelection() {
        let prefs = PlaybackPreferencesStore(defaults: UserDefaults(suiteName: "test-68-\(UUID())")!)
        var current = episode("e1")
        let czech = current.audioTracks.first { $0.id == "e1-cs" }!
        current = current.selectingAudioTrack(czech).selectingSubtitleTrack(nil)

        let next = prefs.appliedToNextEpisode(episode("e2"), continuing: current)
        #expect(next.selectedAudioTrack?.languageCode == "cze")
        #expect(next.selectedSubtitleTrackID == nil)   // Off carries over
    }

    @Test("applied(to:) seeds the default audio language when present")
    func appliedSeedsDefaults() {
        let defaults = UserDefaults(suiteName: "test-68b-\(UUID())")!
        let prefs = PlaybackPreferencesStore(defaults: defaults)
        prefs.defaultAudioLanguage = "cze"
        let seeded = prefs.applied(to: episode("e3"))
        #expect(seeded.selectedAudioTrack?.languageCode == "cze")
    }
}
