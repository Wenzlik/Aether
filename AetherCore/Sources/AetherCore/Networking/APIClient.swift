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

    public init(session: URLSession = .shared) {
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
