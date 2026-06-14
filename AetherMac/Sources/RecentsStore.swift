import SwiftUI

/// Recently-opened files for the Home screen. Dev slice persists plain paths in
/// UserDefaults; the App Store build will switch to security-scoped bookmarks
/// alongside sandbox + play-in-place (#232).
@MainActor
@Observable
final class RecentsStore {
    private let key = "mac.recentFiles"
    private(set) var urls: [URL] = []

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        urls = paths.map { URL(fileURLWithPath: $0) }
    }

    func add(_ url: URL) {
        urls.removeAll { $0 == url }
        urls.insert(url, at: 0)
        if urls.count > 12 { urls = Array(urls.prefix(12)) }
        UserDefaults.standard.set(urls.map(\.path), forKey: key)
    }
}
