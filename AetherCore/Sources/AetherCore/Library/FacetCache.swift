import Foundation

// MARK: - Facet entries (cross-source merge)

/// One display row backed by every source's matching facet value — e.g. the
/// "Marvel" collection on both Plex and Jellyfin collapses to one row whose
/// grid queries both.
public struct CollectionEntry: Identifiable, Hashable, Sendable {
    public var id: String { title.lowercased() }
    public let title: String
    public let childCount: Int?
    public let members: [MediaCollection]

    public init(title: String, childCount: Int?, members: [MediaCollection]) {
        self.title = title
        self.childCount = childCount
        self.members = members
    }
}

public struct PersonEntry: Identifiable, Hashable, Sendable {
    public var id: String { name.lowercased() }
    public let name: String
    public let kind: PersonKind
    public let members: [MediaPerson]
    /// First available headshot across the deduped source variants (#297).
    public var photoURL: URL? {
        members.lazy.compactMap { $0.artwork?.posterURL(.thumbnail) }.first
    }

    public init(name: String, kind: PersonKind, members: [MediaPerson]) {
        self.name = name
        self.kind = kind
        self.members = members
    }
}

/// Process-shared cache for the deduped facet lists. Collections / Actors /
/// Directors fan out to every server on each visit, which read as a long blank
/// load; cache the result (keyed by the source set + kind) so re-visits are
/// instant within a session. Long-ish TTL — facets change rarely.
public actor FacetCache {
    public static let shared = FacetCache()

    private struct Entry<Value> { let value: Value; let at: ContinuousClock.Instant }
    private var collectionStore: [String: Entry<[CollectionEntry]>] = [:]
    private var peopleStore: [String: Entry<[PersonEntry]>] = [:]
    private let ttl: Duration = .seconds(10 * 60)
    private let clock = ContinuousClock()

    public func collections(for key: String) -> [CollectionEntry]? {
        guard let e = collectionStore[key], e.at.duration(to: clock.now) < ttl else { return nil }
        return e.value
    }
    public func setCollections(_ value: [CollectionEntry], for key: String) {
        guard !value.isEmpty else { return }
        collectionStore[key] = Entry(value: value, at: clock.now)
    }
    public func people(for key: String) -> [PersonEntry]? {
        guard let e = peopleStore[key], e.at.duration(to: clock.now) < ttl else { return nil }
        return e.value
    }
    public func setPeople(_ value: [PersonEntry], for key: String) {
        guard !value.isEmpty else { return }
        peopleStore[key] = Entry(value: value, at: clock.now)
    }
}
