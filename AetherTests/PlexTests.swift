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

    @Test("requestPIN sends X-Plex headers, defaults to strong=false, decodes the response")
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

        // strong=false → the short 4-character code humans can type at
        // plex.tv/link. strong=true returns a long token-style PIN that's
        // unusable in a manual sign-in flow.
        let query = request.url?.query ?? ""
        #expect(query.contains("strong=false"))
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

// MARK: - Resource fixture helpers

private extension PlexAPI.Resource.Connection {
    static func make(
        uri: String = "https://example.plex.direct:32400",
        address: String = "192.168.1.10",
        port: Int = 32400,
        local: Bool = false,
        relay: Bool = false,
        connectionProtocol: String = "https"
    ) -> PlexAPI.Resource.Connection {
        .init(uri: uri, address: address, port: port, local: local, relay: relay, connectionProtocol: connectionProtocol)
    }
}

private extension PlexAPI.Resource {
    static func make(
        name: String = "Server",
        clientIdentifier: String = "id",
        provides: String = "server",
        owned: Bool = true,
        accessToken: String? = "tok",
        connections: [Connection] = [.make()]
    ) -> PlexAPI.Resource {
        .init(
            name: name,
            product: "Plex Media Server",
            clientIdentifier: clientIdentifier,
            provides: provides,
            owned: owned,
            accessToken: accessToken,
            connections: connections
        )
    }
}

@Suite("Plex — PlexServerSelector filtering")
struct PlexServerSelectorFilteringTests {

    @Test("Filters out resources that don't provide server")
    func dropsNonServers() {
        let resources: [PlexAPI.Resource] = [
            .make(name: "Server", provides: "server"),
            .make(name: "Player", provides: "player"),
            .make(name: "Multi", provides: "client,player")
        ]
        let kept = PlexServerSelector().mediaServers(from: resources)
        #expect(kept.map(\.name) == ["Server"])
    }

    @Test("Filters out resources without an accessToken")
    func dropsTokenless() {
        let resources: [PlexAPI.Resource] = [
            .make(name: "WithToken", accessToken: "abc"),
            .make(name: "Tokenless", accessToken: nil),
            .make(name: "EmptyToken", accessToken: "")
        ]
        let kept = PlexServerSelector().mediaServers(from: resources)
        #expect(kept.map(\.name) == ["WithToken"])
    }

    @Test("Filters out resources with zero connections")
    func dropsConnectionless() {
        let resources: [PlexAPI.Resource] = [
            .make(name: "Reachable", connections: [.make()]),
            .make(name: "Unreachable", connections: [])
        ]
        let kept = PlexServerSelector().mediaServers(from: resources)
        #expect(kept.map(\.name) == ["Reachable"])
    }

    @Test("Recognises 'server' inside a comma-separated provides field")
    func acceptsMultiProvider() {
        let resources: [PlexAPI.Resource] = [
            .make(name: "Combo", provides: "server,client")
        ]
        let kept = PlexServerSelector().mediaServers(from: resources)
        #expect(kept.map(\.name) == ["Combo"])
    }
}

@Suite("Plex — PlexServerSelector ranking")
struct PlexServerSelectorRankingTests {

    private let selector = PlexServerSelector()

    @Test("Local + non-relay + HTTPS beats remote + relay + HTTPS")
    func localBeatsRemote() {
        let local = PlexAPI.Resource.Connection.make(local: true, relay: false, connectionProtocol: "https")
        let remote = PlexAPI.Resource.Connection.make(local: false, relay: true, connectionProtocol: "https")
        let server = PlexAPI.Resource.make()

        #expect(selector.score(server: server, connection: local) > selector.score(server: server, connection: remote))
    }

    @Test("Direct (non-relay) beats relay even when both are remote")
    func directBeatsRelay() {
        let direct = PlexAPI.Resource.Connection.make(local: false, relay: false, connectionProtocol: "https")
        let relay = PlexAPI.Resource.Connection.make(local: false, relay: true, connectionProtocol: "https")
        let server = PlexAPI.Resource.make()
        #expect(selector.score(server: server, connection: direct) > selector.score(server: server, connection: relay))
    }

    @Test("HTTPS beats HTTP at the same locality + relay tier")
    func httpsTiebreak() {
        let https = PlexAPI.Resource.Connection.make(local: false, relay: false, connectionProtocol: "https")
        let http  = PlexAPI.Resource.Connection.make(local: false, relay: false, connectionProtocol: "http")
        let server = PlexAPI.Resource.make()
        #expect(selector.score(server: server, connection: https) > selector.score(server: server, connection: http))
    }

    @Test("Owned server is preferred over shared at the same connection tier")
    func ownedTiebreak() {
        let conn = PlexAPI.Resource.Connection.make(local: true, relay: false, connectionProtocol: "https")
        let owned = PlexAPI.Resource.make(name: "MyTower", owned: true)
        let friend = PlexAPI.Resource.make(name: "Friend", owned: false)
        #expect(selector.score(server: owned, connection: conn) > selector.score(server: friend, connection: conn))
    }

    @Test("selectBest picks the local+direct+https connection from a mixed pool")
    func selectBestPicksLocalDirect() throws {
        let localDirect = PlexAPI.Resource.Connection.make(uri: "https://local", local: true, relay: false, connectionProtocol: "https")
        let remoteDirect = PlexAPI.Resource.Connection.make(uri: "https://remote", local: false, relay: false, connectionProtocol: "https")
        let relay = PlexAPI.Resource.Connection.make(uri: "https://relay", local: false, relay: true, connectionProtocol: "https")

        let server = PlexAPI.Resource.make(name: "Tower", connections: [relay, remoteDirect, localDirect])
        let pick = try #require(selector.selectBest(from: [server]))
        #expect(pick.connection.uri == "https://local")
        #expect(pick.server.name == "Tower")
    }

    @Test("selectBest returns nil when no resources qualify")
    func selectBestReturnsNilWhenEmpty() {
        let onlyPlayer = PlexAPI.Resource.make(provides: "player")
        #expect(selector.selectBest(from: [onlyPlayer]) == nil)
    }

    @Test("selectBest carries Selection.makeRecord() with all connections ranked best-first")
    func selectionMakesUsableRecord() throws {
        let local = PlexAPI.Resource.Connection.make(uri: "https://lan.plex.direct:32400", local: true, relay: false, connectionProtocol: "https")
        let remote = PlexAPI.Resource.Connection.make(uri: "https://wan.plex.direct:32400", local: false, relay: false, connectionProtocol: "https")
        let relay = PlexAPI.Resource.Connection.make(uri: "https://relay.plex.direct:443", local: false, relay: true, connectionProtocol: "https")
        // Deliberately out of rank order to prove makeRecord sorts them.
        let server = PlexAPI.Resource.make(name: "Tower", clientIdentifier: "pms-uuid", accessToken: "srv-token", connections: [relay, remote, local])

        let pick = try #require(selector.selectBest(from: [server]))
        let record = pick.makeRecord()

        #expect(record.clientIdentifier == "pms-uuid")
        #expect(record.name == "Tower")
        #expect(record.accessToken == "srv-token")
        // Ranked: local first, then direct remote, then relay.
        #expect(record.connections.map(\.uri) == [
            "https://lan.plex.direct:32400",
            "https://wan.plex.direct:32400",
            "https://relay.plex.direct:443"
        ])
        #expect(record.connections.first?.isLocal == true)
        #expect(record.connections.last?.isRelay == true)
        #expect(record.primaryURL?.absoluteString == "https://lan.plex.direct:32400")
    }
}

@Suite("Plex — PlexServerStore round-trip")
struct PlexServerStoreTests {

    /// In-memory `KeychainStore` substitute would be cleaner, but writing the
    /// real Keychain from a test bundle works as long as the bundle has its
    /// own service namespace. Each test uses a unique service to stay isolated.
    private func makeStore(suffix: String = UUID().uuidString) -> PlexServerStore {
        let keychain = KeychainStore(service: "cz.zmrhal.aether.tests.\(suffix)")
        return PlexServerStore(keychain: keychain)
    }

    private func sampleRecord() -> PlexServerRecord {
        PlexServerRecord(
            clientIdentifier: "uuid",
            name: "Tower",
            accessToken: "token",
            connections: [
                .init(uri: "https://lan:32400", isLocal: true, isRelay: false),
                .init(uri: "https://relay:443", isLocal: false, isRelay: true)
            ]
        )
    }

    @Test("write → read returns the same record")
    func writeReadRoundTrip() async throws {
        let store = makeStore()
        let record = sampleRecord()
        try await store.write(record)
        let read = try await store.read()
        #expect(read == record)
    }

    @Test("read returns nil when nothing has been written")
    func readEmpty() async throws {
        let store = makeStore()
        let read = try await store.read()
        #expect(read == nil)
    }

    @Test("clear removes the persisted record")
    func clearRemoves() async throws {
        let store = makeStore()
        try await store.write(sampleRecord())
        try await store.clear()
        let read = try await store.read()
        #expect(read == nil)
    }
}

@Suite("Plex — PlexResourceClient")
struct PlexResourceClientTests {

    private static let config = PlexConfiguration(
        product: "Aether", version: "0.2.0", clientIdentifier: "id",
        deviceName: "iPhone", platform: "iOS", platformVersion: "26.0"
    )

    @Test("resources(token:) hits /api/v2/resources with X-Plex-Token + includeHttps/includeRelay")
    func sendsExpectedRequest() async throws {
        let api = RecordingAPIClient()
        await api.enqueue(.init(
            data: Data("[]".utf8),
            statusCode: 200,
            headers: ["Content-Type": "application/json"]
        ))

        let client = PlexResourceClient(api: api, configuration: Self.config)
        _ = try await client.resources(token: "the-token")

        let recorded = await api.requests
        try #require(recorded.count == 1)
        let request = recorded[0]
        #expect(request.url?.path == "/api/v2/resources")
        let query = request.url?.query ?? ""
        #expect(query.contains("includeHttps=1"))
        #expect(query.contains("includeRelay=1"))
        #expect(request.value(forHTTPHeaderField: "X-Plex-Token") == "the-token")
        #expect(request.value(forHTTPHeaderField: "X-Plex-Product") == "Aether")
    }

    @Test("resources(token:) decodes the array shape correctly")
    func decodesArray() async throws {
        let api = RecordingAPIClient()
        let json = #"""
        [
          {
            "name": "Tower",
            "product": "Plex Media Server",
            "clientIdentifier": "pms-uuid",
            "provides": "server",
            "owned": true,
            "accessToken": "srv-token",
            "connections": [
              {"protocol":"https","address":"192.168.1.10","port":32400,"uri":"https://lan:32400","local":true,"relay":false}
            ]
          }
        ]
        """#
        await api.enqueue(.init(data: Data(json.utf8), statusCode: 200, headers: [:]))

        let client = PlexResourceClient(api: api, configuration: Self.config)
        let resources = try await client.resources(token: "t")

        try #require(resources.count == 1)
        #expect(resources[0].name == "Tower")
        #expect(resources[0].connections.first?.local == true)
    }
}

@Suite("Plex — Library response decoding")
struct PlexLibraryDecodingTests {

    @Test("LibrarySectionsResponse decodes the MediaContainer + Directory shape")
    func decodesSectionsResponse() throws {
        let json = #"""
        {
          "MediaContainer": {
            "Directory": [
              {"key":"1","title":"Movies","type":"movie"},
              {"key":"2","title":"TV","type":"show"},
              {"key":"3","title":"Music","type":"artist"}
            ]
          }
        }
        """#
        let response = try JSONDecoder().decode(PlexAPI.LibrarySectionsResponse.self, from: Data(json.utf8))
        let directories = try #require(response.mediaContainer.directory)
        #expect(directories.count == 3)
        #expect(directories.map(\.kind) == [.movie, .show, nil])
    }

    @Test("LibraryItemsResponse decodes the MediaContainer + Metadata shape")
    func decodesItemsResponse() throws {
        let json = #"""
        {
          "MediaContainer": {
            "Metadata": [
              {
                "ratingKey":"123",
                "type":"movie",
                "title":"Blade Runner 2049",
                "summary":"Thirty years after…",
                "year":2017,
                "duration":9780000,
                "thumb":"/library/metadata/123/thumb/1700000000",
                "art":"/library/metadata/123/art/1700000000"
              }
            ]
          }
        }
        """#
        let response = try JSONDecoder().decode(PlexAPI.LibraryItemsResponse.self, from: Data(json.utf8))
        let items = try #require(response.mediaContainer.metadata)
        #expect(items.count == 1)
        #expect(items[0].title == "Blade Runner 2049")
        #expect(items[0].duration == 9780000)   // milliseconds
    }

    @Test("Empty Metadata array is decoded as nil (Plex omits the key)")
    func decodesEmptyItemsResponse() throws {
        let json = #"""
        { "MediaContainer": {} }
        """#
        let response = try JSONDecoder().decode(PlexAPI.LibraryItemsResponse.self, from: Data(json.utf8))
        #expect(response.mediaContainer.metadata == nil)
    }
}

@Suite("Plex — PlexMediaSource library + items + mapping")
struct PlexMediaSourceLibrariesTests {

    private static let config = PlexConfiguration(
        product: "Aether", version: "0.2.0", clientIdentifier: "id",
        deviceName: "iPhone", platform: "iOS", platformVersion: "26.0"
    )
    private func makeSource(
        api: any APIClient,
        connections: [PlexServerRecord.Connection] = [.init(uri: "https://lan.plex.direct:32400", isLocal: true, isRelay: false)]
    ) -> PlexMediaSource {
        PlexMediaSource(
            serverID: "test-server",
            displayName: "Test",
            accessToken: "srv-token",
            connections: connections,
            configuration: Self.config,
            api: api,
            probeTimeout: 1
        )
    }

    /// Enqueue a successful `/identity` probe — `resolveBaseURL()` hits this
    /// before the first real request.
    private func enqueueReachable(_ api: RecordingAPIClient) async {
        await api.enqueue(.init(data: Data("{}".utf8), statusCode: 200, headers: [:]))
    }

    @Test("libraries() filters out non-movie / non-show library sections")
    func librariesFiltering() async throws {
        let api = RecordingAPIClient()
        await enqueueReachable(api)   // /identity probe
        let json = #"""
        {
          "MediaContainer": {
            "Directory": [
              {"key":"1","title":"Movies","type":"movie"},
              {"key":"2","title":"TV","type":"show"},
              {"key":"3","title":"Music","type":"artist"}
            ]
          }
        }
        """#
        await api.enqueue(.init(data: Data(json.utf8), statusCode: 200, headers: [:]))

        let source = makeSource(api: api)
        let libraries = try await source.libraries()

        #expect(libraries.count == 2)
        #expect(libraries.map(\.title) == ["Movies", "TV"])
        #expect(libraries.map(\.kind) == [.movie, .show])
    }

    @Test("items(in:) hits /library/sections/{key}/all and maps Metadata to MediaItem")
    func itemsEndpointAndMapping() async throws {
        let api = RecordingAPIClient()
        await enqueueReachable(api)   // /identity probe
        let json = #"""
        {
          "MediaContainer": {
            "Metadata": [
              {
                "ratingKey":"123",
                "type":"movie",
                "title":"Sample Movie",
                "summary":"A test.",
                "year":2024,
                "duration":7200000,
                "thumb":"/library/metadata/123/thumb/1",
                "art":"/library/metadata/123/art/1",
                "Media":[
                  {"Part":[{"key":"/library/parts/55/1700/file.mp4"}]}
                ]
              }
            ]
          }
        }
        """#
        await api.enqueue(.init(data: Data(json.utf8), statusCode: 200, headers: [:]))

        let source = makeSource(api: api)
        let libraryID = Library.ID(source: .plex(serverID: "test-server"), rawValue: "7")
        let items = try await source.items(in: libraryID)

        // Endpoint shape — the /all request is the second recorded request
        // (the /identity probe is first).
        let recorded = await api.requests
        try #require(recorded.count == 2)
        let req = recorded[1]
        #expect(req.url?.path == "/library/sections/7/all")
        #expect(req.value(forHTTPHeaderField: "X-Plex-Token") == "srv-token")

        // Mapping
        try #require(items.count == 1)
        let item = items[0]
        #expect(item.title == "Sample Movie")
        #expect(item.kind == .movie)
        #expect(item.year == 2024)
        #expect(item.runtime == .seconds(7200))   // 7_200_000ms → 7200s

        // Tokenised poster + backdrop URLs
        let poster = try #require(item.posterURL)
        #expect(poster.path == "/library/metadata/123/thumb/1")
        #expect(poster.query?.contains("X-Plex-Token=srv-token") == true)

        let backdrop = try #require(item.backdropURL)
        #expect(backdrop.path == "/library/metadata/123/art/1")
        #expect(backdrop.query?.contains("X-Plex-Token=srv-token") == true)

        // Direct-play stream URL from the first Part, tokenised.
        let stream = try #require(item.streamURL)
        #expect(stream.path == "/library/parts/55/1700/file.mp4")
        #expect(stream.query?.contains("X-Plex-Token=srv-token") == true)
    }

    @Test("items without Media (e.g. a show container) get a nil streamURL")
    func containerHasNoStreamURL() async throws {
        let api = RecordingAPIClient()
        await enqueueReachable(api)
        let json = #"""
        {
          "MediaContainer": {
            "Metadata": [
              {"ratingKey":"900","type":"show","title":"A Series","year":2020}
            ]
          }
        }
        """#
        await api.enqueue(.init(data: Data(json.utf8), statusCode: 200, headers: [:]))

        let source = makeSource(api: api)
        let libraryID = Library.ID(source: .plex(serverID: "test-server"), rawValue: "3")
        let items = try await source.items(in: libraryID)

        try #require(items.count == 1)
        #expect(items[0].kind == .show)
        #expect(items[0].streamURL == nil)   // containers aren't directly playable
    }

    @Test("Connection failover: skips an unreachable connection, uses the next reachable one")
    func connectionFailover() async throws {
        let api = RecordingAPIClient()
        await api.enqueue(.init(data: Data("{}".utf8), statusCode: 500, headers: [:]))  // LAN /identity fails
        await api.enqueue(.init(data: Data("{}".utf8), statusCode: 200, headers: [:]))  // remote /identity OK
        await api.enqueue(.init(data: Data(#"{"MediaContainer":{"Directory":[]}}"#.utf8), statusCode: 200, headers: [:]))

        let source = makeSource(api: api, connections: [
            .init(uri: "https://lan.example:32400", isLocal: true, isRelay: false),
            .init(uri: "https://remote.example:32400", isLocal: false, isRelay: false)
        ])
        _ = try await source.libraries()

        let recorded = await api.requests
        try #require(recorded.count == 3)
        #expect(recorded[0].url?.host == "lan.example")       // probed LAN first
        #expect(recorded[0].url?.path == "/identity")
        #expect(recorded[1].url?.host == "remote.example")    // failed over to remote
        #expect(recorded[1].url?.path == "/identity")
        #expect(recorded[2].url?.host == "remote.example")    // real request uses the reachable one
        #expect(recorded[2].url?.path == "/library/sections")
    }

    @Test("Resolution throws when no connection is reachable")
    func noReachableConnection() async throws {
        let api = RecordingAPIClient()
        await api.enqueue(.init(data: Data("{}".utf8), statusCode: 500, headers: [:]))
        let source = makeSource(api: api, connections: [
            .init(uri: "https://lan.example:32400", isLocal: true, isRelay: false)
        ])
        await #expect(throws: PlexConnectionError.noReachableConnection) {
            _ = try await source.libraries()
        }
    }

    @Test("tokenisedURL handles nil + empty relative paths gracefully")
    func tokenisedURLEdges() {
        let source = makeSource(api: RecordingAPIClient())
        let base = URL(string: "https://lan.example:32400")!
        #expect(source.tokenisedURL(base: base, path: nil) == nil)
        #expect(source.tokenisedURL(base: base, path: "") == nil)
    }

    @Test("mapMetadataToMediaItem converts milliseconds duration correctly")
    func runtimeConversion() {
        let dto = PlexAPI.Metadata(
            ratingKey: "x",
            type: "movie",
            title: "X",
            summary: nil,
            year: nil,
            duration: 1500,    // 1.5s in ms
            thumb: nil,
            art: nil,
            media: nil
        )
        let source = makeSource(api: RecordingAPIClient())
        let base = URL(string: "https://lan.example:32400")!
        let item = source.mapMetadataToMediaItem(dto, base: base)
        #expect(item.runtime == .seconds(1.5))
    }
}

@Suite("Plex — PlexMediaSource request shape")
struct PlexMediaSourceRequestTests {

    @Test("request(base:path:) attaches X-Plex-Token and common headers")
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
            accessToken: "server-token",
            connections: [.init(uri: "https://example.plex.direct:32400", isLocal: true, isRelay: false)],
            configuration: config,
            api: URLSessionAPIClient()
        )

        let base = URL(string: "https://example.plex.direct:32400")!
        let request = source.request(base: base, path: "/library/sections", queryItems: [URLQueryItem(name: "type", value: "1")])

        #expect(request.url?.path == "/library/sections")
        #expect(request.url?.query?.contains("type=1") == true)
        #expect(request.value(forHTTPHeaderField: "X-Plex-Token") == "server-token")
        #expect(request.value(forHTTPHeaderField: "X-Plex-Product") == "Aether")
    }
}
