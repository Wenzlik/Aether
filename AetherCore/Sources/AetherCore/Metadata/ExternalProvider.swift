import Foundation

/// A streaming service a title is available on, surfaced as an **availability**
/// signal — not a playback `MediaSource`. Aether never streams these; it only
/// shows where a title can also be watched and links out (#360).
///
/// Data comes from TMDb Watch Providers (powered by JustWatch). `logoURL` is the
/// provider's TMDb-served logo — the license-clean image to render for a badge.
///
/// Provider-generic on purpose: TMDb returns every provider, but only Netflix is
/// wired today (`AGENTS`: wait for the fourth call site before generalising the
/// UI). New providers slot in by adding a constant below.
public struct ExternalProvider: Sendable, Codable, Hashable, Identifiable {
    /// TMDb provider id (stable across the API).
    public let id: Int
    public let name: String
    /// The provider's TMDb-served logo, when known — preferred badge image.
    public let logoURL: URL?

    public init(id: Int, name: String, logoURL: URL? = nil) {
        self.id = id
        self.name = name
        self.logoURL = logoURL
    }

    /// TMDb's provider id for Netflix.
    public static let netflixID = 8

    public var isNetflix: Bool { id == Self.netflixID }
}
