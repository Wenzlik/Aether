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

    @Test("plexAccountLabel reflects 'Connected as <name>' when a server is selected")
    func accountLabelWithServer() {
        let session = makeSession()
        session.isPlexSignedIn = true
        session.plexServer = sampleServer(name: "Living Room")

        let viewModel = SettingsViewModel(session: session)
        #expect(viewModel.plexAccountLabel == "Connected as Living Room")
        #expect(viewModel.connectedServerName == "Living Room")
    }

    @Test("plexAccountLabel reads 'Signed in' when signed in but no server picked yet")
    func accountLabelSignedInOnly() {
        let session = makeSession()
        session.isPlexSignedIn = true
        session.plexServer = nil

        let viewModel = SettingsViewModel(session: session)
        #expect(viewModel.plexAccountLabel == "Signed in")
    }

    @Test("plexAccountLabel reads 'Not connected' when no session at all")
    func accountLabelSignedOut() {
        let session = makeSession()
        session.isPlexSignedIn = false

        let viewModel = SettingsViewModel(session: session)
        #expect(viewModel.plexAccountLabel == "Not connected")
        #expect(viewModel.connectedServerName == nil)
    }

    @Test("plexSourceLabel mirrors session.isPlexSignedIn")
    func sourceLabel() {
        let session = makeSession()
        let viewModel = SettingsViewModel(session: session)

        session.isPlexSignedIn = false
        #expect(viewModel.plexSourceLabel == "Not connected")

        session.isPlexSignedIn = true
        #expect(viewModel.plexSourceLabel == "Connected")
    }

    @Test("Coming-soon labels are constant strings")
    func comingSoonLabels() {
        let viewModel = SettingsViewModel(session: makeSession())
        #expect(viewModel.synologySourceLabel == "Coming soon")
        #expect(viewModel.transcodingLabel == "Coming soon")
        #expect(viewModel.offlineDownloadsLabel == "Coming soon")
        #expect(viewModel.directPlayLabel == "Available")
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

    @Test("signOut() routes through AppSession.signOutOfPlex and dismisses the sheet")
    func signOutDelegatesAndDismisses() async {
        let session = makeSession()
        session.isPlexSignedIn = true
        session.plexServer = sampleServer()
        session.isSettingsPresented = true

        let viewModel = SettingsViewModel(session: session)
        await viewModel.signOut()

        #expect(session.isPlexSignedIn == false)
        #expect(session.plexServer == nil)
        #expect(session.isSettingsPresented == false)
    }
}
