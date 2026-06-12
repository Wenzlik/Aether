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

    /// Split a configured root ("HD" or "HD/Movies") into the SMB **share name**
    /// (the first path component) and the **path within that share** (leading
    /// "/"). AMSMB2 connects per-share, so browsing needs them separated.
    static func splitShareAndPath(_ root: String) -> (share: String, path: String) {
        let parts = root.split(separator: "/").map(String.init)
        guard let share = parts.first else { return ("", "/") }
        let rest = parts.dropFirst().joined(separator: "/")
        return (share, rest.isEmpty ? "/" : "/\(rest)")
    }
}

extension URL {
    /// Rewrite an `smb://` URL to `smb2://` so libVLC forces the **libsmb2**
    /// (SMB2/3) access module instead of letting **libdsm** (SMB1) claim the
    /// scheme for browsing. libdsm can't talk to a NAS with SMB1 disabled (the
    /// default on modern Synology / Windows) — it stalls on NetBIOS name
    /// resolution (`netbios_ns_resolve`) and the browse/playback times out. The
    /// vendored VLCKit registers `smb2` as a module shortcut, so the scheme name
    /// selects the module; the smb2 module reads host/path from the parsed URL,
    /// so the scheme string itself is irrelevant to libsmb2. We keep `smb://`
    /// everywhere else (MediaID, storage, PlaybackEngine routing) and swap to
    /// `smb2://` only at the VLCKit boundary. No-op for any other scheme.
    var forcingSMB2VLCModule: URL {
        guard scheme == "smb" else { return self }
        var comps = URLComponents(url: self, resolvingAgainstBaseURL: false)
        comps?.scheme = "smb2"
        return comps?.url ?? self
    }
}

/// Builds the VLC MRL + media options for a libsmb2 (SMB2/3) request.
///
/// Two things libsmb2 needs that the plain `smb://` + options form didn't give:
/// 1. the **`smb2://` scheme** so libVLC picks libsmb2, not the SMB1 `dsm` module
///    (which stalls on NetBIOS against SMB1-disabled NAS);
/// 2. the **username + domain folded into the URL** (`smb2://domain;user@host/share`)
///    — libsmb2 reads the identity from the URL, NOT from VLC's `smb-user` /
///    `smb-domain` options, so passing them only as options left the session
///    anonymous and the NAS refused it even with valid credentials (confirmed:
///    the macOS SMB client authenticates fine with the very same creds). The
///    password still rides as `:smb-pwd=` (libsmb2 takes it via vlc_credential).
///
/// No-op for non-`smb` URLs (HTTP / local files pass straight through).
func smb2VLCRequest(url: URL, options: [String]) -> (url: URL, options: [String]) {
    guard url.scheme == "smb", let host = url.host else {
        return (url.forcingSMB2VLCModule, options)
    }
    var user: String?
    var domain: String?
    var passthrough: [String] = []
    for opt in options {
        if opt.hasPrefix(":smb-user=") { user = String(opt.dropFirst(10)) }
        else if opt.hasPrefix(":smb-domain=") { domain = String(opt.dropFirst(12)) }
        else { passthrough.append(opt) }   // keeps :smb-pwd= and :network-caching=
    }
    func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? s
    }
    var auth = ""
    if let user, !user.isEmpty {
        if let domain, !domain.isEmpty { auth += enc(domain) + ";" }   // domain;user@
        auth += enc(user) + "@"
    }
    let portPart = url.port.map { ":\($0)" } ?? ""
    let path = url.path.isEmpty ? "/" : url.path   // already percent-encoded by URL
    let built = URL(string: "smb2://\(auth)\(host)\(portPart)\(path)")
    return (built ?? url.forcingSMB2VLCModule, passthrough)
}
