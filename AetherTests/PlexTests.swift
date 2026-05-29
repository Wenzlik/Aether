import Testing
import Foundation
@testable import AetherCore

// MARK: - In-memory APIClient stub

/// Records every request and replies with pre-canned `(Data, HTTPURLResponse)` tuples.
/// Use `enqueue(_:)` to push responses in the order they'll be served.
actor RecordingAPIClient: APIClient {
    struct Response: Sendable {
        let data: Data
        let statusCode: Int
        let headers: [String: String]
    }

    private(set) var requests: [URLRequest] = []
    private var responses: [Response] = []

    func enqueue(_ response: Response) {
        responses.append(response)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else {
            throw APIClientError.unexpectedStatus(0)
        }
        let r = responses.removeFirst()
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: r.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: r.headers
        )!
        return (r.data, http)
    }
}

// MARK: - Suites

@Suite("Plex — common headers")
struct PlexHeadersTests {

    @Test("PlexConfiguration emits every X-Plex header plus Accept: application/json")
    func headersAreComplete() {
        let config = PlexConfiguration(
            product: "Aether",
            version: "0.2.0",
            clientIdentifier: "11111111-2222-3333-4444-555555555555",
            deviceName: "iPhone",
            platform: "iOS",
            platformVersion: "26.0"
        )

        let headers = config.commonHeaders
        #expect(headers["Accept"] == "application/json")
        #expect(headers["X-Plex-Product"] == "Aether")
        #expect(headers["X-Plex-Version"] == "0.2.0")
        #expect(headers["X-Plex-Client-Identifier"] == "11111111-2222-3333-4444-555555555555")
        #expect(headers["X-Plex-Device-Name"] == "iPhone")
        #expect(headers["X-Plex-Platform"] == "iOS")
        #expect(headers["X-Plex-Platform-Version"] == "26.0")
    }
}

@Suite("Plex — PIN decoding")
struct PlexPINDecodingTests {

    @Test("PIN decodes the un-authed shape (authToken null)")
    func decodesUnauthedPIN() throws {
        let json = #"""
        {
          "id": 12345,
          "code": "ABCD",
          "authToken": null,
          "expiresAt": "2099-01-01T00:00:00Z"
        }
        """#

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let pin = try decoder.decode(PlexAPI.PIN.self, from: Data(json.utf8))

        #expect(pin.id == 12345)
        #expect(pin.code == "ABCD")
        #expect(pin.authToken == nil)
        #expect(pin.expiresAt != nil)
    }

    @Test("PIN decodes the authed shape (authToken populated)")
    func decodesAuthedPIN() throws {
        let json = #"""
        {
          "id": 67890,
          "code": "WXYZ",
          "authToken": "the-token",
          "expiresAt": "2099-01-01T00:00:00Z"
        }
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let pin = try decoder.decode(PlexAPI.PIN.self, from: Data(json.utf8))

        #expect(pin.authToken == "the-token")
    }
}

@Suite("Plex — Resource decoding")
struct PlexResourceDecodingTests {

    @Test("Resource decodes a typical Plex server entry with one connection")
    func decodesOneServer() throws {
        let json = #"""
        [
          {
            "name": "MyTower",
            "product": "Plex Media Server",
            "clientIdentifier": "pms-uuid",
            "provides": "server",
            "owned": true,
            "accessToken": "server-token",
            "connections": [
              {
                "protocol": "https",
                "address": "192.168.1.10",
                "port": 32400,
                "uri": "https://192-168-1-10.uuid.plex.direct:32400",
                "local": true,
                "relay": false
              }
            ]
          }
        ]
        """#
        let resources = try JSONDecoder().decode([PlexAPI.Resource].self, from: Data(json.utf8))
        try #require(resources.count == 1)

        let server = resources[0]
        #expect(server.name == "MyTower")
        #expect(server.providesServer == true)
        #expect(server.accessToken == "server-token")
        #expect(server.connections.first?.connectionProtocol == "https")
        #expect(server.connections.first?.local == true)
    }
}

@Suite("Plex — PlexAuthClient flow")
struct PlexAuthClientTests {

    private static let config = PlexConfiguration(
        product: "Aether",
        version: "0.2.0",
        clientIdentifier: "test-client",
        deviceName: "TestDevice",
        platform: "iOS",
        platformVersion: "26.0"
    )

    @Test("requestPIN sends X-Plex headers and decodes the response")
    func requestPINSendsHeaders() async throws {
        let api = RecordingAPIClient()
        await api.enqueue(.init(
            data: Data(#"{"id":1,"code":"AAAA","authToken":null,"expiresAt":null}"#.utf8),
            statusCode: 200,
            headers: ["Content-Type": "application/json"]
        ))

        let auth = PlexAuthClient(api: api, configuration: Self.config)
        let pin = try await auth.requestPIN()

        #expect(pin.id == 1)
        #expect(pin.code == "AAAA")

        let recorded = await api.requests
        try #require(recorded.count == 1)
        let request = recorded[0]
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "X-Plex-Product") == "Aether")
        #expect(request.value(forHTTPHeaderField: "X-Plex-Client-Identifier") == "test-client")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test("pollForToken returns the token once it appears")
    func pollSucceeds() async throws {
        let api = RecordingAPIClient()
        // First two polls: no token. Third: token arrives.
        await api.enqueue(.init(
            data: Data(#"{"id":1,"code":"AAAA","authToken":null,"expiresAt":"2099-01-01T00:00:00Z"}"#.utf8),
            statusCode: 200, headers: [:]
        ))
        await api.enqueue(.init(
            data: Data(#"{"id":1,"code":"AAAA","authToken":null,"expiresAt":"2099-01-01T00:00:00Z"}"#.utf8),
            statusCode: 200, headers: [:]
        ))
        await api.enqueue(.init(
            data: Data(#"{"id":1,"code":"AAAA","authToken":"the-token","expiresAt":"2099-01-01T00:00:00Z"}"#.utf8),
            statusCode: 200, headers: [:]
        ))

        let auth = PlexAuthClient(api: api, configuration: Self.config)
        let token = try await auth.pollForToken(
            pinID: 1,
            interval: .milliseconds(10),
            timeout: .seconds(2)
        )
        #expect(token == "the-token")
    }

    @Test("pollForToken throws .expired when the PIN's expiresAt has passed")
    func pollExpired() async throws {
        let api = RecordingAPIClient()
        await api.enqueue(.init(
            data: Data(#"{"id":1,"code":"AAAA","authToken":null,"expiresAt":"2000-01-01T00:00:00Z"}"#.utf8),
            statusCode: 200, headers: [:]
        ))

        let auth = PlexAuthClient(api: api, configuration: Self.config)
        await #expect(throws: PlexAuthError.expired) {
            _ = try await auth.pollForToken(
                pinID: 1,
                interval: .milliseconds(10),
                timeout: .seconds(2)
            )
        }
    }

    @Test("linkURL embeds the PIN code")
    func linkURLContainsCode() async {
        let auth = PlexAuthClient(api: RecordingAPIClient(), configuration: Self.config)
        let pin = PlexAPI.PIN(id: 1, code: "ABCD", authToken: nil, expiresAt: nil)
        let url = auth.linkURL(for: pin)
        #expect(url.absoluteString.contains("pin=ABCD"))
        #expect(url.host == "www.plex.tv")
    }
}

@Suite("Plex — PlexSignInViewModel")
@MainActor
struct PlexSignInViewModelTests {

    private static let config = PlexConfiguration(
        product: "Aether",
        version: "0.2.0",
        clientIdentifier: "vm-test",
        deviceName: "TestDevice",
        platform: "iOS",
        platformVersion: "26.0"
    )

    @Test("start() → requesting → awaitingUser → success")
    func happyPath() async throws {
        let api = RecordingAPIClient()
        // requestPIN
        await api.enqueue(.init(
            data: Data(#"{"id":1,"code":"AAAA","authToken":null,"expiresAt":"2099-01-01T00:00:00Z"}"#.utf8),
            statusCode: 200, headers: [:]
        ))
        // first poll: token present
        await api.enqueue(.init(
            data: Data(#"{"id":1,"code":"AAAA","authToken":"the-token","expiresAt":"2099-01-01T00:00:00Z"}"#.utf8),
            statusCode: 200, headers: [:]
        ))

        let auth = PlexAuthClient(api: api, configuration: Self.config)
        let vm = PlexSignInViewModel(authClient: auth, pollInterval: .milliseconds(10), pollTimeout: .seconds(2))

        vm.start()
        try await waitFor({ vm.state }) { state in
            if case .success(token: "the-token") = state { return true }
            return false
        }
    }

    @Test("Expired PIN flips to .failure(.expired)")
    func expiredFlow() async throws {
        let api = RecordingAPIClient()
        await api.enqueue(.init(
            data: Data(#"{"id":1,"code":"AAAA","authToken":null,"expiresAt":"2000-01-01T00:00:00Z"}"#.utf8),
            statusCode: 200, headers: [:]
        ))
        await api.enqueue(.init(
            data: Data(#"{"id":1,"code":"AAAA","authToken":null,"expiresAt":"2000-01-01T00:00:00Z"}"#.utf8),
            statusCode: 200, headers: [:]
        ))

        let auth = PlexAuthClient(api: api, configuration: Self.config)
        let vm = PlexSignInViewModel(authClient: auth, pollInterval: .milliseconds(10), pollTimeout: .seconds(2))

        vm.start()
        try await waitFor({ vm.state }) { state in
            if case .failure(reason: .expired) = state { return true }
            return false
        }
    }

    @Test("cancel() resets to .idle and interrupts the polling task")
    func cancellation() async throws {
        let api = RecordingAPIClient()
        await api.enqueue(.init(
            data: Data(#"{"id":1,"code":"AAAA","authToken":null,"expiresAt":"2099-01-01T00:00:00Z"}"#.utf8),
            statusCode: 200, headers: [:]
        ))
        // Note: we do NOT enqueue more responses — if the poll loop survives
        // cancellation, it will throw .unexpectedStatus on the next iteration
        // and the test will catch that as a wrong terminal state.

        let auth = PlexAuthClient(api: api, configuration: Self.config)
        let vm = PlexSignInViewModel(authClient: auth, pollInterval: .milliseconds(50), pollTimeout: .seconds(2))

        vm.start()
        try await waitFor({ vm.state }) { state in
            if case .awaitingUser = state { return true }
            return false
        }

        vm.cancel()
        try await Task.sleep(for: .milliseconds(100))
        if case .idle = vm.state { } else {
            Issue.record("Expected .idle after cancel, got \(vm.state)")
        }
    }
}

/// Poll `read()` every 10ms until `match` returns true, or fail after `timeout`.
@MainActor
private func waitFor<T>(
    _ read: () -> T,
    timeout: Duration = .seconds(2),
    matches match: (T) -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if match(read()) { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("waitFor timed out; last value: \(read())")
}

@Suite("Plex — PlexMediaSource request shape")
struct PlexMediaSourceRequestTests {

    @Test("request(forPath:) attaches X-Plex-Token and common headers")
    func attachesAuthAndHeaders() {
        let config = PlexConfiguration(
            product: "Aether",
            version: "0.2.0",
            clientIdentifier: "id",
            deviceName: "iPhone",
            platform: "iOS",
            platformVersion: "26.0"
        )
        let source = PlexMediaSource(
            serverID: "test-server",
            displayName: "Test",
            baseURL: URL(string: "https://example.plex.direct:32400")!,
            accessToken: "server-token",
            configuration: config,
            api: URLSessionAPIClient()
        )

        let request = source.request(forPath: "/library/sections", queryItems: [URLQueryItem(name: "type", value: "1")])

        #expect(request.url?.path == "/library/sections")
        #expect(request.url?.query?.contains("type=1") == true)
        #expect(request.value(forHTTPHeaderField: "X-Plex-Token") == "server-token")
        #expect(request.value(forHTTPHeaderField: "X-Plex-Product") == "Aether")
    }
}
