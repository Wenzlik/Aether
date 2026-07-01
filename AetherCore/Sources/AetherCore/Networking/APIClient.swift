import Foundation

/// The one seam every media source goes through to talk to a network.
///
/// Plex and Synology each construct full `URLRequest`s (with their own headers,
/// auth, base URL) and hand them to an `APIClient`. The protocol stays
/// deliberately small so tests can drop in a fake without mocking URLSession.
public protocol APIClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

// MARK: - URLSession implementation

public struct URLSessionAPIClient: APIClient {
    private let session: URLSession

    /// A shared session with **bounded** timeouts for JSON API calls.
    ///
    /// `URLSession.shared` defaults to a 60 s request timeout and a **7-day**
    /// resource timeout. On a self-hosted / LAN media server that goes quiet
    /// (Wi-Fi↔cellular handoff, a sleeping NAS, a wedged reverse proxy) an
    /// `await` on a small API call — a Plex transcode decision, a Jellyfin
    /// `PlaybackInfo`, a library page for the Search discovery rails — then
    /// hangs far longer than a user will wait, surfacing as a frozen spinner
    /// that only clears when the screen is re-entered. These are lightweight
    /// JSON calls, never large media downloads (those ride the DownloadManager's
    /// own background session), so short caps are safe and fail fast into the
    /// fallback path. A per-request `timeoutInterval` still overrides
    /// `timeoutIntervalForRequest` where a call wants a tighter bound (e.g. the
    /// Plex reachability probe and the transcode warm-up).
    private static let bounded: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15    // idle wait for the next packet
        config.timeoutIntervalForResource = 60   // hard ceiling for the whole call
        config.waitsForConnectivity = false      // fail fast off-network, don't park the request
        return URLSession(configuration: config)
    }()

    /// Uses the shared, timeout-bounded session (see `bounded`).
    public init() {
        self.session = URLSessionAPIClient.bounded
    }

    /// Inject a specific session (tests, or a caller that needs different limits).
    public init(session: URLSession) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIClientError.nonHTTPResponse
        }
        return (data, http)
    }
}

// MARK: - Errors

public enum APIClientError: Error, Sendable, Equatable {
    case nonHTTPResponse
    case unexpectedStatus(Int)
    case decoding(message: String)
}

// MARK: - Convenience

public extension APIClient {
    /// Fetch and decode a `Decodable` value, validating the HTTP status against
    /// `acceptableStatusCodes` (default: 200..<300).
    func decode<T: Decodable & Sendable>(
        _ type: T.Type,
        from request: URLRequest,
        acceptableStatusCodes: Range<Int> = 200..<300,
        decoder: JSONDecoder = .init()
    ) async throws -> T {
        let (data, response) = try await self.data(for: request)
        guard acceptableStatusCodes.contains(response.statusCode) else {
            throw APIClientError.unexpectedStatus(response.statusCode)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIClientError.decoding(message: String(describing: error))
        }
    }
}
