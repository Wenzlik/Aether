import Foundation

/// A unified, source-agnostic media item.
///
/// Both Plex and Synology connectors map their native types into `MediaItem`
/// so views, navigation, and playback never have to branch on the source.
public struct MediaItem: Identifiable, Hashable, Sendable {
    public let id: MediaID
    public let title: String
    public let kind: Kind
    public let year: Int?
    public let runtime: Duration?
    public let summary: String?
    public let posterURL: URL?
    public let backdropURL: URL?
    public let streamURL: URL?
    public let audioTracks: [MediaAudioTrack]
    public let selectedAudioTrackID: String?

    public init(
        id: MediaID,
        title: String,
        kind: Kind,
        year: Int? = nil,
        runtime: Duration? = nil,
        summary: String? = nil,
        posterURL: URL? = nil,
        backdropURL: URL? = nil,
        streamURL: URL? = nil,
        audioTracks: [MediaAudioTrack] = [],
        selectedAudioTrackID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.year = year
        self.runtime = runtime
        self.summary = summary
        self.posterURL = posterURL
        self.backdropURL = backdropURL
        self.streamURL = streamURL
        self.audioTracks = audioTracks
        self.selectedAudioTrackID = selectedAudioTrackID ?? audioTracks.first(where: \.isSelected)?.id
    }

    public var selectedAudioTrack: MediaAudioTrack? {
        guard let selectedAudioTrackID else { return nil }
        return audioTracks.first { $0.id == selectedAudioTrackID }
    }

    /// Whether playback start/seek is handled by the server (Plex universal
    /// transcode) rather than the local `AVPlayer`. A transcode session emits
    /// HLS from a fixed start offset, so seeking the player into a from-zero
    /// transcode requests segments the server never produced — surfacing as
    /// `NSURLErrorDomain -1008`. For these we bake the start position into the
    /// URL (`offset`) instead of seeking. Direct-play files seek client-side.
    public var isServerTranscode: Bool {
        guard let streamURL else { return false }
        return streamURL.path.contains("/transcode/universal/start")
    }

    /// Return a copy whose stream begins at `seconds`.
    ///
    /// For server-transcode URLs this writes a Plex `offset` query item so the
    /// transcoder starts producing segments from that point. For direct-play
    /// it's a no-op — the caller seeks the `AVPlayer` instead. A non-positive
    /// `seconds` returns `self` unchanged (start from the beginning).
    public func startingPlayback(at seconds: Double) -> MediaItem {
        guard seconds > 0, isServerTranscode, let streamURL else { return self }
        let offset = String(Int(seconds.rounded()))
        return replacingStreamURL(streamURL.replacingQueryItem(name: "offset", value: offset))
    }

    public func selectingAudioTrack(_ track: MediaAudioTrack) -> MediaItem {
        let nextTracks = audioTracks.map { $0.withSelection($0.id == track.id) }
        return MediaItem(
            id: id,
            title: title,
            kind: kind,
            year: year,
            runtime: runtime,
            summary: summary,
            posterURL: posterURL,
            backdropURL: backdropURL,
            // Set the new track *and* mint a fresh Plex transcode session.
            // Plex keys a running transcode by its `session` id: re-requesting
            // `start.m3u8` with the same session but a different `audioStreamID`
            // just resumes the existing transcode and the new track is ignored
            // — the stream keeps playing the old audio. A new session forces
            // the server to start a transcode that honours the selection.
            streamURL: streamURL?
                .replacingQueryItem(name: "audioStreamID", value: track.id)
                .regeneratingPlexTranscodeSession(),
            audioTracks: nextTracks,
            selectedAudioTrackID: track.id
        )
    }

    /// Copy with a different stream URL, preserving every other field.
    private func replacingStreamURL(_ url: URL?) -> MediaItem {
        MediaItem(
            id: id,
            title: title,
            kind: kind,
            year: year,
            runtime: runtime,
            summary: summary,
            posterURL: posterURL,
            backdropURL: backdropURL,
            streamURL: url,
            audioTracks: audioTracks,
            selectedAudioTrackID: selectedAudioTrackID
        )
    }

    public enum Kind: String, Sendable, Hashable {
        case movie
        case episode
        case show
        case season

        /// Whether this kind is a container browsed into for children (a show's
        /// seasons, a season's episodes) rather than played directly.
        public var isContainer: Bool {
            self == .show || self == .season
        }
    }
}

public struct MediaAudioTrack: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let languageCode: String?
    public let codec: String?
    public let channels: Int?
    public let isSelected: Bool

    public init(
        id: String,
        title: String,
        languageCode: String? = nil,
        codec: String? = nil,
        channels: Int? = nil,
        isSelected: Bool = false
    ) {
        self.id = id
        self.title = title
        self.languageCode = languageCode
        self.codec = codec
        self.channels = channels
        self.isSelected = isSelected
    }

    public var displayTitle: String {
        var pieces: [String] = []
        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedTitle.isEmpty {
            pieces.append(cleanedTitle)
        } else if let languageCode, !languageCode.isEmpty {
            pieces.append(languageCode.uppercased())
        } else {
            pieces.append("Audio")
        }
        if let codec, !codec.isEmpty {
            pieces.append(codec.uppercased())
        }
        if let channels {
            pieces.append("\(channels) ch")
        }
        return pieces.joined(separator: " - ")
    }

    public func withSelection(_ selected: Bool) -> MediaAudioTrack {
        MediaAudioTrack(
            id: id,
            title: title,
            languageCode: languageCode,
            codec: codec,
            channels: channels,
            isSelected: selected
        )
    }
}

/// Identity of a media item, scoped by its source.
public struct MediaID: Hashable, Sendable {
    public let source: MediaSourceID
    public let rawValue: String

    public init(source: MediaSourceID, rawValue: String) {
        self.source = source
        self.rawValue = rawValue
    }
}

/// Identifies which source (mock / Plex server / Synology share) an item came from.
public enum MediaSourceID: Hashable, Sendable {
    case mock
    case plex(serverID: String)
    case synology(host: String)

    /// A stable, run-to-run identical string for this source. Suitable as a
    /// component of persistence keys (e.g. per-library preferences). The
    /// default `String(describing:)` reflects the underlying Swift enum
    /// representation and is *not* stable across compiler versions, so we
    /// hand-roll one here.
    public var stableKey: String {
        switch self {
        case .mock:
            return "mock"
        case .plex(let serverID):
            return "plex.\(serverID)"
        case .synology(let host):
            return "synology.\(host)"
        }
    }
}

private extension URL {
    func replacingQueryItem(name: String, value: String) -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return self
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == name }
        queryItems.append(URLQueryItem(name: name, value: value))
        components.queryItems = queryItems
        return components.url ?? self
    }

    /// Mint a fresh Plex transcode session id on a `start.m3u8` URL so the
    /// server starts a new transcode instead of resuming the running one.
    /// No-op for direct-play URLs, which carry no `session` query item.
    func regeneratingPlexTranscodeSession() -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              queryItems.contains(where: { $0.name == "session" }) else {
            return self
        }
        let fresh = UUID().uuidString
        components.queryItems = queryItems.map { item in
            switch item.name {
            case "session", "X-Plex-Session-Identifier":
                return URLQueryItem(name: item.name, value: fresh)
            default:
                return item
            }
        }
        return components.url ?? self
    }
}
