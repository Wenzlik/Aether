import Foundation

/// In-memory media source used during 0.1 Foundation before real connectors land.
public actor MockMediaSource: MediaSource {
    public let id: MediaSourceID = .mock
    public let displayName = "Mock Library"

    private let store: [Library: [MediaItem]]

    public init() {
        let featured = Library(
            id: .init(source: .mock, rawValue: "featured"),
            title: "Featured",
            kind: .movie
        )

        let sampleURL = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8")

        let items: [MediaItem] = [
            MediaItem(
                id: .init(source: .mock, rawValue: "sample-1"),
                title: "Sample Title",
                kind: .movie,
                year: 2026,
                runtime: .seconds(60 * 90),
                summary: "A placeholder used during early development.",
                streamURL: sampleURL
            )
        ]

        self.store = [featured: items]
    }

    public func libraries() async throws -> [Library] {
        Array(store.keys).sorted { $0.title < $1.title }
    }

    public func items(in libraryID: Library.ID) async throws -> [MediaItem] {
        store.first { $0.key.id == libraryID }?.value ?? []
    }
}
