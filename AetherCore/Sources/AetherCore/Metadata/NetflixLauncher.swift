import Foundation

/// Builds the link-out URL for "Play on Netflix" (#360). Aether never streams
/// Netflix — it hands off to the Netflix app (or web).
///
/// v1 uses a **search URL** (`https://www.netflix.com/search?q=<title>`): TMDb
/// doesn't return a Netflix title id or a direct deep link, so an exact-title
/// deep link would need a second, paid provider (tracked as a follow-up). The
/// HTTPS universal link opens the Netflix app when installed, else the web.
///
/// The actual open is done by each app target (`openURL` on iOS/visionOS,
/// `NSWorkspace` on macOS) — this just builds the URL and says where it applies.
public enum NetflixLauncher {
    /// The search URL for a title, or nil if it can't be encoded.
    public static func searchURL(title: String) -> URL? {
        let q = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
        return URL(string: "https://www.netflix.com/search?q=\(q)")
    }

    /// Whether "Play on Netflix" can launch on this platform. tvOS has no
    /// browser and no reliable app-to-app launch, so there it's badge + discovery
    /// only — the action is hidden.
    public static var canLaunch: Bool {
        #if os(tvOS)
        return false
        #else
        return true
        #endif
    }
}
