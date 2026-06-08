import Foundation

/// Persists the user's recent **search queries** so the Search tab can offer
/// them before typing. UserDefaults-backed and `@Observable`, mirroring the
/// other small preference stores. Cross-platform.
///
/// Most-recent-first, de-duplicated case-insensitively, and capped — recording
/// happens on submit (not per keystroke).
@Observable
@MainActor
public final class RecentSearchesStore {

    /// Recent queries, newest first.
    public private(set) var recent: [String]

    private let defaults: UserDefaults
    private let maxCount: Int
    private static let key = "search.recentQueries"

    public init(defaults: UserDefaults = .standard, maxCount: Int = 10) {
        self.defaults = defaults
        self.maxCount = maxCount
        self.recent = defaults.stringArray(forKey: Self.key) ?? []
    }

    /// Record a submitted query: trim, drop empties, move an existing match to
    /// the front (case-insensitive de-dup), and cap the list.
    public func record(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = recent.filter { $0.localizedCaseInsensitiveCompare(trimmed) != .orderedSame }
        list.insert(trimmed, at: 0)
        if list.count > maxCount { list = Array(list.prefix(maxCount)) }
        recent = list
        defaults.set(list, forKey: Self.key)
    }

    /// Forget all recent queries.
    public func clear() {
        recent = []
        defaults.removeObject(forKey: Self.key)
    }
}
