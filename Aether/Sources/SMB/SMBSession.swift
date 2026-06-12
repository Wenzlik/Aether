import Foundation
import SMBClient

/// One native SMB directory entry. `path` is share-relative (no leading "/", the
/// form `SMBClient.listDirectory` expects) and is used to recurse; `streamURL`
/// is the credential-free `smb://` URL for playback.
struct SMBNativeEntry: Sendable, Hashable {
    let name: String
    let path: String          // within the share, e.g. "Movies/Film.mkv"
    let isDirectory: Bool
    let streamURL: URL
}

/// Native SMB2/3 browse + auth via the pure-Swift **SMBClient** package,
/// replacing the VLCKit bridge for browsing (#213/#214).
///
/// Why native: VLC's `libsmb2` was an opaque black box — it never surfaced an
/// auth error and never reliably triggered iOS's Local Network prompt, so SMB
/// failed on-device even with valid credentials. SMBClient is pure Swift over
/// Network framework: it throws concrete errors (`localizedDescription` shows
/// the real reason) and authenticates like a real client. VLCKit stays for MKV
/// *playback* only; SMB file streaming will move to a local HTTP range proxy
/// later (this layer is browse + auth).
///
/// A **value type** on purpose: the package's `SMBClient` is a non-`Sendable`
/// class, so it's created and fully used inside a single call here and never
/// stored or sent across an isolation boundary (which Swift 6 region isolation
/// would reject). Each call logs in fresh — fine, because the recursive walk is
/// done in one `walkVideos` call per share, not one connection per directory.
struct SMBSession: Sendable {
    let connection: SMBConnection

    private func loggedIn() async throws -> SMBClient {
        let client = SMBClient(host: connection.host)
        try await client.login(
            username: connection.username ?? "",
            password: connection.password ?? ""
        )
        return client
    }

    /// The server's shares — for host-root browse when no folder is set.
    func shares() async throws -> [String] {
        let client = try await loggedIn()
        return try await client.listShares().map(\.name)
    }

    /// Connect to `share` and list one directory (`path`). Throws the real SMB
    /// error — used to validate a connection in the sign-in screen.
    func list(share: String, path: String) async throws -> [SMBNativeEntry] {
        let client = try await loggedIn()
        try await client.connectShare(share)
        let relative = Self.relative(path)
        let listing = try await client.listDirectory(path: relative)
        return Self.map(listing, share: share, parent: relative, connection: connection)
    }

    /// Breadth-first walk of `share` from `basePath`, returning video files
    /// (depth- and count-capped). Logs in + connects once; best-effort
    /// (swallows per-directory errors so one unreadable folder doesn't abort).
    func walkVideos(
        share: String,
        basePath: String,
        maxDepth: Int,
        maxFiles: Int,
        videoExtensions: Set<String>
    ) async -> [SMBNativeEntry] {
        guard let client = try? await loggedIn() else { return [] }
        do { try await client.connectShare(share) } catch { return [] }

        var results: [SMBNativeEntry] = []
        var queue: [(path: String, depth: Int)] = [(Self.relative(basePath), 0)]
        while !queue.isEmpty, results.count < maxFiles {
            let (path, depth) = queue.removeFirst()
            guard depth <= maxDepth else { continue }
            let listing = (try? await client.listDirectory(path: path)) ?? []
            for entry in Self.map(listing, share: share, parent: path, connection: connection) {
                if results.count >= maxFiles { break }
                if entry.isDirectory {
                    queue.append((entry.path, depth + 1))
                } else if videoExtensions.contains((entry.name as NSString).pathExtension.lowercased()) {
                    results.append(entry)
                }
            }
        }
        return results
    }

    // MARK: - Helpers

    /// SMBClient paths are share-relative with no leading slash ("" = root).
    private static func relative(_ path: String) -> String {
        path.hasPrefix("/") ? String(path.dropFirst()) : path
    }

    private static func map(
        _ listing: [File],
        share: String,
        parent: String,
        connection: SMBConnection
    ) -> [SMBNativeEntry] {
        listing.compactMap { file -> SMBNativeEntry? in
            let name = file.name
            guard name != ".", name != ".." else { return nil }
            let childPath = parent.isEmpty ? name : "\(parent)/\(name)"
            guard let streamURL = connection.url(forPath: "\(share)/\(childPath)") else { return nil }
            return SMBNativeEntry(name: name, path: childPath, isDirectory: file.isDirectory, streamURL: streamURL)
        }
    }
}
