import Testing
import Foundation
@testable import AetherCore

@Suite("AetherCore — Foundation")
struct AetherCoreFoundationTests {

    @Test("MockMediaSource lists at least one library and one item")
    func mockSourceHasContent() async throws {
        let source = MockMediaSource()
        let libraries = try await source.libraries()
        try #require(!libraries.isEmpty)

        let items = try await source.items(in: libraries[0].id)
        try #require(!items.isEmpty)
        #expect(items[0].streamURL != nil)
    }

    @Test("PlaybackSession transitions idle → loading → playing → paused")
    func playbackTransitions() async throws {
        let session = PlaybackSession()

        let initial = await session.state
        #expect(initial.status == .idle)

        let item = MediaItem(
            id: .init(source: .mock, rawValue: "test"),
            title: "Test",
            kind: .movie
        )

        await session.prepare(item: item)
        var state = await session.state
        #expect(state.status == .loading)

        await session.play()
        state = await session.state
        #expect(state.status == .playing)

        await session.pause()
        state = await session.state
        #expect(state.status == .paused)
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
