import Foundation

/// In-memory media source used during 0.1 Foundation before real connectors land.
///
/// Two ways to construct it:
/// - `MockMediaSource()` — a single hardcoded item, useful for previews and unit tests.
/// - `MockMediaSource(fixture:)` — loads from a `MockFixture` (typically parsed from
///   `Aether/Resources/MockLibrary.json`); the path the running app uses.
public actor MockMediaSource: MediaSource {
    public let id: MediaSourceID = .mock
    public let displayName = "Mock Library"

    private let libraryList: [Library]
    private let itemsByLibrary: [Library.ID: [MediaItem]]
    private let itemIndex: [MediaID: MediaItem]
    private let featuredIDs: [MediaID]
    private let seededResumePoints: [ResumePoint]

    // MARK: - Public surface

    /// Items the curator has chosen to feature on the Home hero / first rail.
    public var featuredItems: [MediaItem] {
        get async { featuredIDs.compactMap { itemIndex[$0] } }
    }

    /// Resume points the fixture ships pre-populated, so Continue Watching has content on first launch.
    public var simulatedResumePoints: [ResumePoint] {
        get async { seededResumePoints }
    }

    // MARK: - Init

    /// Convenience initialiser with a single sample item. Useful in previews and tests.
    public init() {
        let library = Library(
            id: .init(source: .mock, rawValue: "featured"),
            title: "Featured",
            kind: .movie
        )
        let item = MediaItem(
            id: .init(source: .mock, rawValue: "sample-1"),
            title: "Sample Title",
            kind: .movie,
            year: 2026,
            runtime: .seconds(60 * 90),
            summary: "A placeholder used during early development.",
            streamURL: URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8")
        )

        self.libraryList = [library]
        self.itemsByLibrary = [library.id: [item]]
        self.itemIndex = [item.id: item]
        self.featuredIDs = [item.id]
        self.seededResumePoints = []
    }

    /// Build a mock source from a decoded fixture (typically loaded from `MockLibrary.json`).
    public init(fixture: MockFixture) {
        let defaultStream = URL(string: fixture.sampleStreamURL)

        let libraries: [Library] = fixture.libraries.map { dto in
            Library(
                id: .init(source: .mock, rawValue: dto.id),
                title: dto.title,
                kind: dto.kind.kind
            )
        }
        let libraryIDByRaw: [String: Library.ID] = Dictionary(
            uniqueKeysWithValues: libraries.map { ($0.id.rawValue, $0.id) }
        )

        var grouped: [Library.ID: [MediaItem]] = [:]
        var index: [MediaID: MediaItem] = [:]

        for itemDTO in fixture.items {
            guard let libraryID = libraryIDByRaw[itemDTO.library] else { continue }
            let item = MediaItem(
                id: .init(source: .mock, rawValue: itemDTO.id),
                title: itemDTO.title,
                kind: itemDTO.kind.kind,
                year: itemDTO.year,
                runtime: itemDTO.runtimeSeconds.map { .seconds($0) },
                summary: itemDTO.summary,
                posterURL: itemDTO.posterURL.flatMap(URL.init(string:)),
                backdropURL: itemDTO.backdropURL.flatMap(URL.init(string:)),
                streamURL: itemDTO.streamURL.flatMap(URL.init(string:)) ?? defaultStream
            )
            grouped[libraryID, default: []].append(item)
            index[item.id] = item
        }

        let featuredMediaIDs: [MediaID] = fixture.featured.map {
            MediaID(source: .mock, rawValue: $0)
        }

        let resumePoints: [ResumePoint] = fixture.resumePoints.map { dto in
            ResumePoint(
                mediaID: .init(source: .mock, rawValue: dto.itemID),
                position: .seconds(dto.positionSeconds)
            )
        }

        self.libraryList = libraries
        self.itemsByLibrary = grouped
        self.itemIndex = index
        self.featuredIDs = featuredMediaIDs
        self.seededResumePoints = resumePoints
    }

    // MARK: - Loading from a bundle

    /// Convenience: load `MockLibrary.json` from a bundle.
    /// - Parameter bundle: the bundle to look in. The app target passes `.main`; tests may pass their own.
    /// - Parameter name: the JSON file name without extension. Defaults to `MockLibrary`.
    public static func loadFromBundle(_ bundle: Bundle = .main, named name: String = "MockLibrary") throws -> MockMediaSource {
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw MockMediaSourceError.fixtureNotFound(name: name)
        }
        let data = try Data(contentsOf: url)
        let fixture = try JSONDecoder().decode(MockFixture.self, from: data)
        return MockMediaSource(fixture: fixture)
    }

    // MARK: - MediaSource

    public func libraries() async throws -> [Library] { libraryList }

    public func items(in libraryID: Library.ID) async throws -> [MediaItem] {
        itemsByLibrary[libraryID] ?? []
    }

    /// Direct item lookup. Used by `HomeFeedBuilder` and the resume-store seeding step.
    public func item(for id: MediaID) async -> MediaItem? {
        itemIndex[id]
    }
}

// MARK: - Errors

public enum MockMediaSourceError: Error, Sendable {
    case fixtureNotFound(name: String)
}

// MARK: - Fixture DTOs

/// On-disk schema for `MockLibrary.json`. Decoded once at startup.
public struct MockFixture: Decodable, Sendable {
    public let sampleStreamURL: String
    public let libraries: [Library]
    public let items: [Item]
    public let featured: [String]
    public let resumePoints: [ResumePoint]

    public struct Library: Decodable, Sendable {
        public let id: String
        public let title: String
        public let kind: ItemKind
    }

    public struct Item: Decodable, Sendable {
        public let id: String
        public let title: String
        public let kind: ItemKind
        public let library: String
        public let year: Int?
        public let runtimeSeconds: Int?
        public let summary: String?
        public let posterURL: String?
        public let backdropURL: String?
        public let streamURL: String?
    }

    public struct ResumePoint: Decodable, Sendable {
        public let itemID: String
        public let positionSeconds: Int
    }

    public enum ItemKind: String, Decodable, Sendable {
        case movie
        case episode
        case show

        var kind: MediaItem.Kind {
            switch self {
            case .movie: return .movie
            case .episode: return .episode
            case .show: return .show
            }
        }
    }
}
