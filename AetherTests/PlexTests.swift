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
        // First poll: still waiting. The view model should stay in
        // `.awaitingUser` until either a token arrives, the PIN expires, or the
        // user cancels.
        await api.enqueue(.init(
            data: Data(#"{"id":1,"code":"AAAA","authToken":null,"expiresAt":"2099-01-01T00:00:00Z"}"#.utf8),
            statusCode: 200, headers: [:]
        ))

        let auth = PlexAuthClient(api: api, configuration: Self.config)
        let vm = PlexSignInViewModel(authClient: auth, pollInterval: .seconds(5), pollTimeout: .seconds(10))

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
        let keychain = KeychainStore(service: "cz.zmrhal.aether.tests.\(suffix)", backing: .memory)
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
                  {"container":"mp4","Part":[{"key":"/library/parts/55/1700/file.mp4"}]}
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

        // mp4 container → direct-play stream URL from the first Part, tokenised.
        let stream = try #require(item.streamURL)
        #expect(stream.path == "/library/parts/55/1700/file.mp4")
        #expect(stream.query?.contains("X-Plex-Token=srv-token") == true)
    }

    @Test("item(for:) hydrates a leaf item with Plex audio streams")
    func itemEndpointHydratesAudioStreams() async throws {
        let api = RecordingAPIClient()
        await enqueueReachable(api)
        let json = #"""
        {
          "MediaContainer": {
            "Metadata": [
              {
                "ratingKey":"123",
                "type":"movie",
                "title":"Multi Audio",
                "Media":[
                  {
                    "container":"mkv",
                    "Part":[
                      {
                        "key":"/library/parts/123/1700/file.mkv",
                        "Stream":[
                          {"id":"1","streamType":1,"codec":"hevc"},
                          {"id":"11","streamType":2,"selected":true,"codec":"aac","language":"English","languageCode":"eng","channels":6},
                          {"id":"12","streamType":2,"selected":false,"codec":"ac3","language":"Czech","languageCode":"ces","channels":2}
                        ]
                      }
                    ]
                  }
                ]
              }
            ]
          }
        }
        """#
        await api.enqueue(.init(data: Data(json.utf8), statusCode: 200, headers: [:]))

        let source = makeSource(api: api)
        let id = MediaID(source: .plex(serverID: "test-server"), rawValue: "123")
        let item = try #require(try await source.item(for: id))

        let recorded = await api.requests
        try #require(recorded.count == 2)
        #expect(recorded[1].url?.path == "/library/metadata/123")
        #expect(item.audioTracks.map(\.id) == ["11", "12"])
        #expect(item.selectedAudioTrackID == "11")

        let stream = try #require(item.streamURL)
        let components = try #require(URLComponents(url: stream, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.first { $0.name == "audioStreamID" }?.value == "11")
    }

    @Test("children(of:) hits /library/metadata/{key}/children and maps seasons")
    func childrenEndpointAndMapping() async throws {
        let api = RecordingAPIClient()
        await enqueueReachable(api)   // /identity probe
        let json = #"""
        {
          "MediaContainer": {
            "Metadata": [
              {"ratingKey":"201","type":"season","title":"Season 1",
               "thumb":"/library/metadata/201/thumb/1"},
              {"ratingKey":"202","type":"season","title":"Season 2"}
            ]
          }
        }
        """#
        await api.enqueue(.init(data: Data(json.utf8), statusCode: 200, headers: [:]))

        let source = makeSource(api: api)
        let showID = MediaID(source: .plex(serverID: "test-server"), rawValue: "200")
        let seasons = try await source.children(of: showID)

        let recorded = await api.requests
        try #require(recorded.count == 2)            // probe + children
        #expect(recorded[1].url?.path == "/library/metadata/200/children")

        #expect(seasons.count == 2)
        #expect(seasons.map(\.kind) == [.season, .season])
        #expect(seasons.map(\.title) == ["Season 1", "Season 2"])
        // Seasons are containers — no stream URL.
        #expect(seasons.allSatisfy { $0.streamURL == nil })
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

    @Test("streamURL: mp4 → direct file, mkv → transcode, container → nil")
    func streamURLDecision() {
        let source = makeSource(api: RecordingAPIClient())
        let base = URL(string: "https://lan.example:32400")!

        let mp4 = PlexAPI.Metadata(
            ratingKey: "1", type: "movie", title: "A", summary: nil, year: nil,
            duration: nil, thumb: nil, art: nil,
            media: [.init(container: "mp4", part: [.init(key: "/library/parts/1/1/a.mp4")])]
        )
        #expect(source.streamURL(for: mp4, base: base)?.path == "/library/parts/1/1/a.mp4")

        let mkv = PlexAPI.Metadata(
            ratingKey: "2", type: "movie", title: "B", summary: nil, year: nil,
            duration: nil, thumb: nil, art: nil,
            media: [.init(container: "mkv", part: [.init(key: "/library/parts/2/1/b.mkv")])]
        )
        #expect(source.streamURL(for: mkv, base: base)?.path == "/video/:/transcode/universal/start.m3u8")

        // Unknown container also routes to transcode (safe default).
        let unknown = PlexAPI.Metadata(
            ratingKey: "3", type: "movie", title: "C", summary: nil, year: nil,
            duration: nil, thumb: nil, art: nil,
            media: [.init(container: nil, part: [.init(key: "/library/parts/3/1/c.dat")])]
        )
        #expect(unknown.firstPartKey != nil)
        #expect(source.streamURL(for: unknown, base: base)?.path == "/video/:/transcode/universal/start.m3u8")

        // No Media (a show container) → nil.
        let show = PlexAPI.Metadata(
            ratingKey: "4", type: "show", title: "D", summary: nil, year: nil,
            duration: nil, thumb: nil, art: nil, media: nil
        )
        #expect(source.streamURL(for: show, base: base) == nil)
    }

    @Test("transcodeURL carries the expected universal-transcoder params")
    func transcodeURLParams() throws {
        let source = makeSource(api: RecordingAPIClient())
        let base = URL(string: "https://lan.example:32400")!
        let url = try #require(source.transcodeURL(base: base, ratingKey: "777"))

        #expect(url.path == "/video/:/transcode/universal/start.m3u8")
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let q = comps.queryItems ?? []
        func value(_ name: String) -> String? { q.first { $0.name == name }?.value }

        #expect(value("path") == "/library/metadata/777")
        #expect(value("protocol") == "hls")
        #expect(value("directPlay") == "0")
        #expect(value("directStream") == "1")
        #expect(value("X-Plex-Token") == "srv-token")
        #expect(value("X-Plex-Client-Identifier") == "id")  // from makeSource's config
        #expect(q.contains { $0.name == "session" })
        #expect(q.contains { $0.name == "X-Plex-Session-Identifier" })
    }

    @Test("Plex audio streams map to selectable tracks and audioStreamID")
    func audioTrackMapping() throws {
        let source = makeSource(api: RecordingAPIClient())
        let base = URL(string: "https://lan.example:32400")!
        let dto = PlexAPI.Metadata(
            ratingKey: "42",
            type: "movie",
            title: "Multi Audio MKV",
            summary: nil,
            year: nil,
            duration: nil,
            thumb: nil,
            art: nil,
            media: [
                .init(
                    container: "mkv",
                    part: [
                        .init(
                            key: "/library/parts/42/1/file.mkv",
                            stream: [
                                .init(id: "10", streamType: 1, codec: "h264"),
                                .init(
                                    id: "11",
                                    streamType: 2,
                                    selected: true,
                                    codec: "aac",
                                    language: "English",
                                    languageCode: "eng",
                                    title: "English 5.1",
                                    channels: 6
                                ),
                                .init(
                                    id: "12",
                                    streamType: 2,
                                    selected: false,
                                    codec: "ac3",
                                    language: "Czech",
                                    languageCode: "ces",
                                    title: "Czech",
                                    channels: 2
                                )
                            ]
                        )
                    ]
                )
            ]
        )

        let item = source.mapMetadataToMediaItem(dto, base: base)
        #expect(item.audioTracks.map(\.id) == ["11", "12"])
        #expect(item.selectedAudioTrackID == "11")

        let initialURL = try #require(item.streamURL)
        let initialComponents = try #require(URLComponents(url: initialURL, resolvingAgainstBaseURL: false))
        #expect(initialComponents.queryItems?.first { $0.name == "audioStreamID" }?.value == "11")

        let czech = try #require(item.audioTracks.last)
        let switched = item.selectingAudioTrack(czech)
        let switchedURL = try #require(switched.streamURL)
        let switchedComponents = try #require(URLComponents(url: switchedURL, resolvingAgainstBaseURL: false))
        #expect(switched.selectedAudioTrackID == "12")
        #expect(switchedComponents.queryItems?.first { $0.name == "audioStreamID" }?.value == "12")
    }

    @Test("Plex subtitle streams map to selectable tracks and subtitleStreamID")
    func subtitleTrackMapping() throws {
        let source = makeSource(api: RecordingAPIClient())
        let base = URL(string: "https://lan.example:32400")!
        let dto = PlexAPI.Metadata(
            ratingKey: "43",
            type: "movie",
            title: "Subtitled MKV",
            summary: nil,
            year: nil,
            duration: nil,
            thumb: nil,
            art: nil,
            media: [
                .init(
                    container: "mkv",
                    part: [
                        .init(
                            key: "/library/parts/43/1/file.mkv",
                            stream: [
                                .init(id: "10", streamType: 1, codec: "h264"),
                                .init(id: "11", streamType: 2, selected: true, codec: "aac", channels: 6),
                                .init(
                                    id: "20",
                                    streamType: 3,
                                    selected: false,
                                    codec: "srt",
                                    language: "English",
                                    languageCode: "eng",
                                    title: "English"
                                ),
                                .init(
                                    id: "21",
                                    streamType: 3,
                                    selected: true,
                                    codec: "srt",
                                    language: "Czech",
                                    languageCode: "ces",
                                    title: "Czech (Forced)"
                                )
                            ]
                        )
                    ]
                )
            ]
        )

        let item = source.mapMetadataToMediaItem(dto, base: base)
        #expect(item.subtitleTracks.map(\.id) == ["20", "21"])
        #expect(item.selectedSubtitleTrackID == "21")
        // Forced status inferred from the title.
        #expect(item.subtitleTracks.last?.isForced == true)
        #expect(item.subtitleTracks.first?.isForced == false)

        // Switching to the English track writes its id.
        let english = try #require(item.subtitleTracks.first)
        let switched = item.selectingSubtitleTrack(english)
        let switchedURL = try #require(switched.streamURL)
        let switchedComponents = try #require(URLComponents(url: switchedURL, resolvingAgainstBaseURL: false))
        #expect(switched.selectedSubtitleTrackID == "20")
        #expect(switchedComponents.queryItems?.first { $0.name == "subtitleStreamID" }?.value == "20")

        // Turning subtitles off writes subtitleStreamID=0 and clears selection.
        let off = item.selectingSubtitleTrack(nil)
        let offURL = try #require(off.streamURL)
        let offComponents = try #require(URLComponents(url: offURL, resolvingAgainstBaseURL: false))
        #expect(off.selectedSubtitleTrackID == nil)
        #expect(offComponents.queryItems?.first { $0.name == "subtitleStreamID" }?.value == "0")
    }

    @Test("resolvePlayback mints a fresh transcode session and carries streams + offset")
    func resolvePlaybackTranscodeIsFresh() async throws {
        let api = RecordingAPIClient()
        await enqueueReachable(api)   // /identity probe (resolveBaseURL caches after)
        // Each resolve warms up the playlist before returning.
        await api.enqueue(.init(data: Data("#EXTM3U".utf8), statusCode: 200, headers: [:]))
        await api.enqueue(.init(data: Data("#EXTM3U".utf8), statusCode: 200, headers: [:]))
        let source = makeSource(api: api)

        let request = PlaybackRequest(
            itemID: .init(source: .plex(serverID: "test-server"), rawValue: "42"),
            mode: .transcode,
            audioStreamID: "11",
            subtitleStreamID: "20",
            startTime: .seconds(90)
        )

        let first = try await source.resolvePlayback(request)
        let second = try await source.resolvePlayback(request)

        #expect(first.isServerTranscode)
        #expect(first.baseOffsetSeconds == 90)

        let c1 = try #require(URLComponents(url: first.url, resolvingAgainstBaseURL: false))
        #expect(c1.queryItems?.first { $0.name == "audioStreamID" }?.value == "11")
        #expect(c1.queryItems?.first { $0.name == "subtitleStreamID" }?.value == "20")
        #expect(c1.queryItems?.first { $0.name == "offset" }?.value == "90")
        #expect(c1.path == "/video/:/transcode/universal/start.m3u8")

        // The whole point of the fix: a brand-new session id each resolve, so a
        // reaped Plex session can't be replayed into a -1008.
        let s1 = c1.queryItems?.first { $0.name == "session" }?.value
        let c2 = try #require(URLComponents(url: second.url, resolvingAgainstBaseURL: false))
        let s2 = c2.queryItems?.first { $0.name == "session" }?.value
        #expect(s1 != nil)
        #expect(s2 != nil)
        #expect(s1 != s2)
    }

    @Test("resolvePlayback direct play returns the stable URL untouched")
    func resolvePlaybackDirectPlay() async throws {
        let source = makeSource(api: RecordingAPIClient())
        let fileURL = URL(string: "https://lan.plex.direct:32400/library/parts/7/1/file.mp4?X-Plex-Token=t")!
        let request = PlaybackRequest(
            itemID: .init(source: .plex(serverID: "test-server"), rawValue: "7"),
            mode: .directPlay,
            directPlayURL: fileURL
        )

        let resolved = try await source.resolvePlayback(request)
        #expect(resolved.url == fileURL)
        #expect(resolved.isServerTranscode == false)
        #expect(resolved.baseOffsetSeconds == 0)
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

@Suite("Plex — PlexMediaSource items(sortedBy:limit:offset:)")
struct PlexMediaSourceSortedItemsTests {

    private static let config = PlexConfiguration(
        product: "Aether", version: "0.2.0", clientIdentifier: "id",
        deviceName: "iPhone", platform: "iOS", platformVersion: "26.0"
    )

    private func makeSource(api: any APIClient) -> PlexMediaSource {
        PlexMediaSource(
            serverID: "test-server",
            displayName: "Test",
            accessToken: "srv-token",
            connections: [.init(uri: "https://lan.plex.direct:32400", isLocal: true, isRelay: false)],
            configuration: Self.config,
            api: api,
            probeTimeout: 1
        )
    }

    private func enqueueReachable(_ api: RecordingAPIClient) async {
        await api.enqueue(.init(data: Data("{}".utf8), statusCode: 200, headers: [:]))
    }

    private let emptyMetadata = #"{"MediaContainer":{}}"#

    @Test("sort=titleSort:asc + start/size query items match the .titleAZ + limit + offset call")
    func sortAndPaginationQueryItems() async throws {
        let api = RecordingAPIClient()
        await enqueueReachable(api)
        await api.enqueue(.init(data: Data(emptyMetadata.utf8), statusCode: 200, headers: [:]))

        let source = makeSource(api: api)
        let libraryID = Library.ID(source: .plex(serverID: "test-server"), rawValue: "1")
        _ = try await source.items(in: libraryID, sortedBy: .titleAZ, limit: 50, offset: 100)

        let recorded = await api.requests
        try #require(recorded.count == 2)            // probe + items
        let request = recorded[1]
        #expect(request.url?.path == "/library/sections/1/all")
        let query = request.url?.query ?? ""
        // URLQueryItem encodes `:` as `%3A` per RFC 3986.
        #expect(query.contains("sort=titleSort%3Aasc") || query.contains("sort=titleSort:asc"))
        #expect(query.contains("X-Plex-Container-Start=100"))
        #expect(query.contains("X-Plex-Container-Size=50"))
    }

    @Test("random sort sends `sort=random` (no direction suffix)")
    func randomSortParameter() async throws {
        let api = RecordingAPIClient()
        await enqueueReachable(api)
        await api.enqueue(.init(data: Data(emptyMetadata.utf8), statusCode: 200, headers: [:]))

        let source = makeSource(api: api)
        let libraryID = Library.ID(source: .plex(serverID: "test-server"), rawValue: "2")
        _ = try await source.items(in: libraryID, sortedBy: .random, limit: nil, offset: nil)

        let recorded = await api.requests
        let query = recorded[1].url?.query ?? ""
        #expect(query.contains("sort=random"))
        // No pagination — keep the URL clean.
        #expect(!query.contains("X-Plex-Container-Start"))
        #expect(!query.contains("X-Plex-Container-Size"))
    }

    @Test("items(in:) without sort defaults to .default (.recentlyAdded → addedAt:desc)")
    func defaultSort() async throws {
        let api = RecordingAPIClient()
        await enqueueReachable(api)
        await api.enqueue(.init(data: Data(emptyMetadata.utf8), statusCode: 200, headers: [:]))

        let source = makeSource(api: api)
        let libraryID = Library.ID(source: .plex(serverID: "test-server"), rawValue: "3")
        _ = try await source.items(in: libraryID)

        let recorded = await api.requests
        let query = recorded[1].url?.query ?? ""
        #expect(query.contains("sort=addedAt%3Adesc") || query.contains("sort=addedAt:desc"))
    }

    @Test("Year (newest) and rating sorts map to their Plex parameters")
    func mappingCheck() async throws {
        for (sort, expected) in [
            (LibrarySort.yearNewest, "year:desc"),
            (LibrarySort.yearOldest, "year:asc"),
            (LibrarySort.ratingHighest, "audienceRating:desc")
        ] {
            let api = RecordingAPIClient()
            await enqueueReachable(api)
            await api.enqueue(.init(data: Data(emptyMetadata.utf8), statusCode: 200, headers: [:]))

            let source = makeSource(api: api)
            let libraryID = Library.ID(source: .plex(serverID: "test-server"), rawValue: "1")
            _ = try await source.items(in: libraryID, sortedBy: sort, limit: nil, offset: nil)

            let query = await api.requests.last?.url?.query ?? ""
            let encoded = expected.replacingOccurrences(of: ":", with: "%3A")
            #expect(
                query.contains("sort=\(expected)") || query.contains("sort=\(encoded)"),
                "expected sort=\(expected) in query for \(sort), got: \(query)"
            )
        }
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

@Suite("Plex — transcode warm-up")
struct PlexTranscodeWarmUpTests {
    private func request() -> URLRequest {
        URLRequest(url: URL(string: "https://server.example/video/:/transcode/universal/start.m3u8")!)
    }

    @Test("warmUp succeeds on HTTP 200 + #EXTM3U")
    func success() async {
        let api = RecordingAPIClient()
        await api.enqueue(.init(data: Data("#EXTM3U\n#EXT-X-VERSION:3".utf8), statusCode: 200, headers: [:]))
        let manager = PlexTranscodeSessionManager(api: api)
        let outcome = await manager.warmUp(request(), delays: [])
        #expect(outcome.ready)
        #expect(outcome.attempts == 1)
        #expect(outcome.sawPlaylistMarker)
    }

    @Test("warmUp retries until the playlist is ready")
    func retries() async {
        let api = RecordingAPIClient()
        await api.enqueue(.init(data: Data("still spinning up".utf8), statusCode: 503, headers: [:]))
        await api.enqueue(.init(data: Data("#EXTM3U".utf8), statusCode: 200, headers: [:]))
        let manager = PlexTranscodeSessionManager(api: api)
        let outcome = await manager.warmUp(request(), delays: [.milliseconds(1)])
        #expect(outcome.ready)
        #expect(outcome.attempts == 2)
    }

    @Test("warmUp fails cleanly when never ready")
    func failsCleanly() async {
        let api = RecordingAPIClient()
        for _ in 0..<3 { await api.enqueue(.init(data: Data("nope".utf8), statusCode: 500, headers: [:])) }
        let manager = PlexTranscodeSessionManager(api: api)
        let outcome = await manager.warmUp(request(), delays: [.milliseconds(1), .milliseconds(1)])
        #expect(!outcome.ready)
        #expect(outcome.attempts == 3)
        #expect(outcome.lastStatus == 500)
        #expect(!outcome.sawPlaylistMarker)
    }
}

@Suite("Plex — resolvePlayback warm-up + offset")
struct PlexResolveWarmUpTests {
    private static let config = PlexConfiguration(
        product: "Aether", version: "0.2.0", clientIdentifier: "cid",
        deviceName: "Test", platform: "iOS", platformVersion: "26"
    )

    private func makeSource(api: any APIClient) -> PlexMediaSource {
        PlexMediaSource(
            serverID: "s", displayName: "D", accessToken: "srv-token",
            connections: [.init(uri: "https://lan.example:32400", isLocal: true, isRelay: false)],
            configuration: Self.config, api: api, probeTimeout: 1, warmUpBackoff: []
        )
    }

    private func enqueueReachable(_ api: RecordingAPIClient) async {
        await api.enqueue(.init(data: Data("{}".utf8), statusCode: 200, headers: [:]))
    }
    private func enqueuePlaylist(_ api: RecordingAPIClient) async {
        await api.enqueue(.init(data: Data("#EXTM3U".utf8), statusCode: 200, headers: [:]))
    }

    @Test("Large offset (>12s) is baked into the URL, with location=lan + fresh session")
    func largeOffsetBaked() async throws {
        let api = RecordingAPIClient()
        await enqueueReachable(api)
        await enqueuePlaylist(api)
        let source = makeSource(api: api)

        let request = PlaybackRequest(
            itemID: .init(source: .plex(serverID: "s"), rawValue: "42"),
            mode: .transcode, audioStreamID: "2", startTime: .seconds(90)
        )
        let resolved = try await source.resolvePlayback(request)

        #expect(resolved.isServerTranscode)
        #expect(resolved.baseOffsetSeconds == 90)
        #expect(resolved.clientSeekSeconds == nil)
        #expect(resolved.transcodeSessionID != nil)

        let c = try #require(URLComponents(url: resolved.url, resolvingAgainstBaseURL: false))
        #expect(c.queryItems?.first { $0.name == "offset" }?.value == "90")
        #expect(c.queryItems?.first { $0.name == "location" }?.value == "lan")
    }

    @Test("Small offset (<=12s) is NOT sent; falls back to client-side seek")
    func smallOffsetClientSeek() async throws {
        let api = RecordingAPIClient()
        await enqueueReachable(api)
        await enqueuePlaylist(api)
        let source = makeSource(api: api)

        let request = PlaybackRequest(
            itemID: .init(source: .plex(serverID: "s"), rawValue: "42"),
            mode: .transcode, startTime: .seconds(5)
        )
        let resolved = try await source.resolvePlayback(request)

        #expect(resolved.baseOffsetSeconds == 0)
        #expect(resolved.clientSeekSeconds == 5)
        let c = try #require(URLComponents(url: resolved.url, resolvingAgainstBaseURL: false))
        #expect(c.queryItems?.contains { $0.name == "offset" } == false)
    }

    @Test("Selecting an audio track sends directStreamAudio=0 so the choice is honoured")
    func audioSelectionTranscodesChosenTrack() async throws {
        let api = RecordingAPIClient()
        await enqueueReachable(api)
        await enqueuePlaylist(api)
        let source = makeSource(api: api)

        let request = PlaybackRequest(
            itemID: .init(source: .plex(serverID: "s"), rawValue: "42"),
            mode: .transcode, audioStreamID: "3"
        )
        let resolved = try await source.resolvePlayback(request)
        let c = try #require(URLComponents(url: resolved.url, resolvingAgainstBaseURL: false))
        #expect(c.queryItems?.first { $0.name == "audioStreamID" }?.value == "3")
        // The fix: a chosen track transcodes only that stream, instead of
        // keeping all renditions (which made AVPlayer ignore the selection).
        #expect(c.queryItems?.first { $0.name == "directStreamAudio" }?.value == "0")
    }

    @Test("With no audio choice, all tracks are kept (directStreamAudio=1)")
    func noAudioChoiceKeepsAllTracks() async throws {
        let api = RecordingAPIClient()
        await enqueueReachable(api)
        await enqueuePlaylist(api)
        let source = makeSource(api: api)

        let request = PlaybackRequest(
            itemID: .init(source: .plex(serverID: "s"), rawValue: "42"),
            mode: .transcode
        )
        let resolved = try await source.resolvePlayback(request)
        let c = try #require(URLComponents(url: resolved.url, resolvingAgainstBaseURL: false))
        #expect(c.queryItems?.first { $0.name == "directStreamAudio" }?.value == "1")
    }

    @Test("Warm-up failure maps to .notReady with token-free diagnostics")
    func warmUpFailureMapsToNotReady() async {
        let api = RecordingAPIClient()
        await enqueueReachable(api)
        await api.enqueue(.init(data: Data("err".utf8), statusCode: 500, headers: [:]))
        let source = makeSource(api: api)

        let request = PlaybackRequest(
            itemID: .init(source: .plex(serverID: "s"), rawValue: "42"),
            mode: .transcode, startTime: .seconds(90)
        )
        do {
            _ = try await source.resolvePlayback(request)
            Issue.record("expected resolvePlayback to throw .notReady")
        } catch let PlaybackResolveError.notReady(diagnostics) {
            #expect(!diagnostics.contains("srv-token"))
            #expect(!diagnostics.lowercased().contains("token"))
            #expect(diagnostics.contains("host=lan.example"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("diagnostics never contain the Plex token")
    func diagnosticsHideToken() {
        let outcome = PlexTranscodeSessionManager.WarmUpOutcome(ready: false, attempts: 5, lastStatus: 404, sawPlaylistMarker: false)
        let diag = PlexMediaSource.diagnostics(
            isLocal: true, base: URL(string: "https://lan.example:32400")!,
            sessionID: "abcdef123456", offset: 90, audioStreamID: "2", subtitleStreamID: nil, outcome: outcome
        )
        #expect(!diag.contains("srv-token"))
        #expect(diag.contains("connection=lan"))
        #expect(diag.contains("host=lan.example"))
    }
}
