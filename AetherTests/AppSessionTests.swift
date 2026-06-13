import Testing
import Foundation
@testable import Aether
@testable import AetherCore

@Suite("AppSession — sign-out")
@MainActor
struct AppSessionSignOutTests {

    /// Each test runs against its own keychain service so the user's real
    /// `cz.zmrhal.aether` items aren't touched.
    private func makeSession(suffix: String = UUID().uuidString) -> AppSession {
        let keychain = KeychainStore(service: "cz.zmrhal.aether.tests.\(suffix)", backing: .memory)
        return AppSession(keychain: keychain)
    }

    private func sampleServer() -> PlexServerRecord {
        PlexServerRecord(
            clientIdentifier: "uuid",
            name: "Tower",
            accessToken: "tok",
            connections: [
                .init(uri: "https://lan:32400", isLocal: true, isRelay: false)
            ]
        )
    }

    @Test("signOutOfPlex resets every Plex-related field to its empty state")
    func resetsAllFields() async {
        let session = makeSession()
        // Seed a signed-in state. Skipping `start()` deliberately so we don't
        // touch the real network; we set the publishable state directly.
        session.isPlexSignedIn = true
        session.applyEnabledPlexServers([sampleServer()])
        session.source = MockMediaSource()
        session.discoveryState = .completed(serverName: "Tower")

        await session.signOutOfPlex()

        #expect(session.isPlexSignedIn == false)
        #expect(session.plexServer == nil)
        #expect(session.plexSource == nil)
        #expect(session.source == nil)
        #expect(session.discoveryState == .idle)
    }

    @Test("signOutOfPlex is idempotent — second call leaves state unchanged")
    func idempotent() async {
        let session = makeSession()
        session.isPlexSignedIn = true
        session.applyEnabledPlexServers([sampleServer()])

        await session.signOutOfPlex()
        // Capture the cleared state, then call again. Nothing should change.
        let firstSnapshot = (
            session.isPlexSignedIn,
            session.plexServer,
            session.source != nil,
            session.discoveryState
        )

        await session.signOutOfPlex()

        #expect(firstSnapshot.0 == session.isPlexSignedIn)
        #expect(firstSnapshot.1 == session.plexServer)
        #expect(firstSnapshot.2 == (session.source != nil))
        #expect(firstSnapshot.3 == session.discoveryState)
    }

    @Test("signOutOfPlex clears the persisted Plex token from the keychain")
    func clearsKeychainToken() async throws {
        let suffix = UUID().uuidString
        let keychain = KeychainStore(service: "cz.zmrhal.aether.tests.\(suffix)", backing: .memory)
        try await keychain.setString("the-token", for: AppSession.plexTokenKey)
        try #require(await keychain.string(for: AppSession.plexTokenKey) == "the-token")

        let session = AppSession(keychain: keychain)
        session.isPlexSignedIn = true
        await session.signOutOfPlex()

        let after = try await keychain.string(for: AppSession.plexTokenKey)
        #expect(after == nil)
    }
}
