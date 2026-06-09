import Testing
import Foundation
@testable import Aether
@testable import AetherCore

@Suite("SettingsViewModel")
@MainActor
struct SettingsViewModelTests {

    private func makeSession() -> AppSession {
        let keychain = KeychainStore(service: "cz.zmrhal.aether.tests.\(UUID().uuidString)", backing: .memory)
        return AppSession(keychain: keychain)
    }

    private func sampleServer(name: String = "Tower") -> PlexServerRecord {
        PlexServerRecord(
            clientIdentifier: "uuid",
            name: name,
            accessToken: "tok",
            connections: [
                .init(uri: "https://lan:32400", isLocal: true, isRelay: false)
            ]
        )
    }

    @Test("plexAccountStatus is Connected + server detail when a server is selected")
    func accountStatusWithServer() {
        let session = makeSession()
        session.isPlexSignedIn = true
        session.plexServer = sampleServer(name: "Living Room")

        let viewModel = SettingsViewModel(session: session)
        #expect(viewModel.plexAccountStatus == .connected)
        #expect(viewModel.connectedServerName == "Living Room")
        #expect(viewModel.connectedServerDetail == "Server: Living Room")
    }

    @Test("plexAccountStatus reads 'Signed in' when signed in but no server picked yet")
    func accountStatusSignedInOnly() {
        let session = makeSession()
        session.isPlexSignedIn = true
        session.plexServer = nil

        let viewModel = SettingsViewModel(session: session)
        #expect(viewModel.plexAccountStatus == .neutral("Signed in"))
        #expect(viewModel.connectedServerDetail == nil)
    }

    @Test("plexAccountStatus reads 'Not connected' when no session at all")
    func accountStatusSignedOut() {
        let session = makeSession()
        session.isPlexSignedIn = false

        let viewModel = SettingsViewModel(session: session)
        #expect(viewModel.plexAccountStatus == .notConnected)
        #expect(viewModel.connectedServerName == nil)
    }

    @Test("plexSourceStatus mirrors session.isPlexSignedIn")
    func sourceStatus() {
        let session = makeSession()
        let viewModel = SettingsViewModel(session: session)

        session.isPlexSignedIn = false
        #expect(viewModel.plexSourceStatus == .notConnected)

        session.isPlexSignedIn = true
        #expect(viewModel.plexSourceStatus == .connected)
    }

    @Test("Synology source still reads 'Coming soon'")
    func staticStatuses() {
        // The old Direct Play / Transcoding / Offline Downloads capability
        // badges retired in 0.4.0 — they were product facts, not user
        // preferences, and the Settings → Playback section now holds
        // configurable defaults instead. Synology is the only static
        // status row left on Settings (it stays "Coming soon" until the
        // Synology source actually ships).
        let viewModel = SettingsViewModel(session: makeSession())
        #expect(viewModel.synologyStatus == .comingSoon)
    }

    @Test("versionString reads CFBundleShortVersionString from Bundle.main and is non-empty")
    func versionStringNonEmpty() {
        let viewModel = SettingsViewModel(session: makeSession())
        // In a test bundle the host app's Info.plist is read; the value depends
        // on project.yml. We just require something readable — not the literal
        // string, since this will move every release.
        #expect(!viewModel.versionString.isEmpty)
        #expect(!viewModel.buildString.isEmpty)
    }

    @Test("signOut() routes through AppSession.signOutOfPlex and resets state")
    func signOutDelegatesAndResets() async {
        let session = makeSession()
        session.isPlexSignedIn = true
        session.plexServer = sampleServer()

        let viewModel = SettingsViewModel(session: session)
        await viewModel.signOut()

        #expect(session.isPlexSignedIn == false)
        #expect(session.plexServer == nil)
        #expect(session.source == nil)
    }
}
