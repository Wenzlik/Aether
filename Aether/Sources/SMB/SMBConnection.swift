import Foundation
import AetherCore

/// A configured SMB share connection (#214). Identified by a stable record
/// UUID — NOT the host — so the user can rename the server or its IP can change
/// without orphaning resume state (`MediaSourceID.smb(id:)` keys off this).
///
/// Credentials live here in memory and in the Keychain (via `SMBConnectionStore`);
/// they are passed to VLCKit as media options and never embedded in URLs.
struct SMBConnection: Codable, Hashable, Sendable, Identifiable {
    let id: String          // stable record UUID
    var host: String        // bare host or IP, e.g. "192.168.1.10" / "nas.lan"
    var displayName: String
    var username: String?
    var password: String?
    var domain: String?
    /// Share/folder paths to scan, relative to the host root (e.g. "Media",
    /// "Media/Movies"). Empty = scan every share found at the host root.
    var roots: [String]

    init(
        id: String = UUID().uuidString,
        host: String,
        displayName: String? = nil,
        username: String? = nil,
        password: String? = nil,
        domain: String? = nil,
        roots: [String] = []
    ) {
        self.id = id
        self.host = host
        self.displayName = displayName ?? host
        self.username = username
        self.password = password
        self.domain = domain
        self.roots = roots
    }

    var sourceID: MediaSourceID { .smb(id: id) }

    /// Base `smb://host/` URL — credential-free (creds go via VLC options).
    var rootURL: URL? { URL(string: "smb://\(host)/") }

    /// A directory URL under this host for a path relative to the root.
    func url(forPath path: String) -> URL? {
        let trimmed = path.split(separator: "/").map(String.init)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
            .joined(separator: "/")
        return URL(string: "smb://\(host)/\(trimmed)")
    }

    /// VLCKit media options carrying the credentials — applied to both browse
    /// `VLCMedia` and the player's media before `play()`. Guest shares → no
    /// auth options (empty array means anonymous).
    var vlcMediaOptions: [String] {
        var options: [String] = [":network-caching=1500"]
        if let username, !username.isEmpty { options.append(":smb-user=\(username)") }
        if let password, !password.isEmpty { options.append(":smb-pwd=\(password)") }
        if let domain, !domain.isEmpty { options.append(":smb-domain=\(domain)") }
        return options
    }
}
