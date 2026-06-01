import Foundation

/// Persists per-library UI preferences (today: sort order; in future: filter
/// chips, view mode, "Keep" flags for offline) in the Keychain.
///
/// One entry per `Library.ID`, keyed by the source's `stableKey` + library
/// raw value, so a "Movies" library on the user's own Plex server keeps its
/// own sort separate from a friend's "Movies" or a Synology share's.
public actor LibraryPreferencesStore {
    /// Common prefix for every entry this store writes. Keeps the user's
    /// Keychain searchable (`security find-generic-password -s …`) and
    /// makes a future `clearAll()` reliable.
    public static let keyPrefix = "library.preferences."

    private let keychain: KeychainStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(keychain: KeychainStore) {
        self.keychain = keychain
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    // MARK: - Sort

    /// Read the persisted sort for a library. `nil` when nothing has been
    /// saved yet — the caller decides what default to render.
    public func sort(for libraryID: Library.ID) async -> LibrarySort? {
        guard let raw = try? await keychain.string(for: key(for: libraryID, kind: .sort)) else {
            return nil
        }
        return LibrarySort(rawValue: raw)
    }

    /// Persist the user's chosen sort for a library. Silent on Keychain
    /// failures — sort is preference, not data; losing it across launches is
    /// recoverable by picking again.
    public func setSort(_ sort: LibrarySort, for libraryID: Library.ID) async {
        try? await keychain.setString(sort.rawValue, for: key(for: libraryID, kind: .sort))
    }

    /// Forget any sort recorded for a library. Used when the source signs out
    /// or the library disappears.
    public func clearSort(for libraryID: Library.ID) async {
        try? await keychain.removeValue(for: key(for: libraryID, kind: .sort))
    }

    // MARK: - Keys

    private enum PreferenceKind: String {
        case sort
    }

    private func key(for libraryID: Library.ID, kind: PreferenceKind) -> String {
        "\(Self.keyPrefix)\(libraryID.source.stableKey).\(libraryID.rawValue).\(kind.rawValue)"
    }
}
