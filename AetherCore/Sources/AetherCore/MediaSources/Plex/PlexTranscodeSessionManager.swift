import Foundation

/// Owns the lifecycle of Plex universal-transcode sessions: minting session
/// ids, **warming up** the HLS playlist before AVPlayer ever sees the URL, and
/// stopping sessions when they're done.
///
/// Why warm-up: Aether mints a fresh transcode session and hands AVPlayer the
/// `start.m3u8` URL. On a live Plex Media Server the playlist / first segment
/// isn't ready the instant the session is created, so AVPlayer opening it too
/// early fails with `NSURLErrorDomain -1008` ("resource unavailable") — which
/// is exactly why playback fails right after an audio switch or a resume but
/// works if the user waits and retries. We fetch the playlist ourselves with
/// short exponential backoff and only return once it's actually readable.
public actor PlexTranscodeSessionManager {
    /// Sanitised, token-free summary of a warm-up attempt for diagnostics.
    public struct WarmUpOutcome: Sendable, Equatable {
        public let ready: Bool
        public let attempts: Int
        public let lastStatus: Int?
        public let sawPlaylistMarker: Bool
    }

    /// Default backoff *before* attempts 2…n (attempt 1 is immediate):
    /// 250 ms, 500 ms, 1 s, 2 s — five tries over ~3.75 s, then give up.
    public static let defaultBackoff: [Duration] = [
        .milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2)
    ]

    private let api: any APIClient
    private(set) var activeSessions: Set<String> = []

    public init(api: any APIClient) {
        self.api = api
    }

    public func newSessionID() -> String {
        UUID().uuidString
    }

    public func markActive(_ id: String) {
        activeSessions.insert(id)
    }

    public func isActive(_ id: String) -> Bool {
        activeSessions.contains(id)
    }

    /// Poll the HLS master playlist until it's readable (HTTP 2xx + a body that
    /// contains `#EXTM3U`) or the backoff is exhausted. Never blocks the main
    /// actor. Returns an outcome with diagnostics; the caller decides whether a
    /// non-ready outcome is fatal.
    public func warmUp(_ request: URLRequest, delays: [Duration] = defaultBackoff) async -> WarmUpOutcome {
        let totalAttempts = delays.count + 1
        var attempt = 0
        var lastStatus: Int?
        var sawMarker = false

        while attempt < totalAttempts {
            if attempt > 0 {
                try? await Task.sleep(for: delays[attempt - 1])
            }
            attempt += 1
            if Task.isCancelled { break }

            do {
                let (data, response) = try await api.data(for: request)
                lastStatus = response.statusCode
                if (200..<300).contains(response.statusCode) {
                    let head = String(decoding: data.prefix(64), as: UTF8.self)
                    sawMarker = head.contains("#EXTM3U")
                    if sawMarker {
                        return WarmUpOutcome(ready: true, attempts: attempt, lastStatus: lastStatus, sawPlaylistMarker: true)
                    }
                }
            } catch {
                lastStatus = nil
            }
        }

        return WarmUpOutcome(ready: false, attempts: attempt, lastStatus: lastStatus, sawPlaylistMarker: sawMarker)
    }

    /// Fire-and-forget stop of a transcode session (`/transcode/universal/stop`).
    public func stop(_ request: URLRequest, sessionID: String) async {
        activeSessions.remove(sessionID)
        _ = try? await api.data(for: request)
    }
}
