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
