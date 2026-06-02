import Testing
import Foundation
@testable import Aether

@Suite("JellyfinSignInViewModel — address parsing")
@MainActor
struct JellyfinSignInViewModelTests {

    @Test("Bare hostname tries HTTPS first, then HTTP")
    func bareHostname() {
        let urls = JellyfinSignInViewModel.candidateURLs("jellyfin.example.com")
        #expect(urls.map(\.absoluteString) == [
            "https://jellyfin.example.com",
            "http://jellyfin.example.com"
        ])
    }

    @Test("IP with explicit port tries HTTP first (typical LAN Jellyfin)")
    func ipWithPort() {
        let urls = JellyfinSignInViewModel.candidateURLs("192.168.1.10:8096")
        #expect(urls.map(\.absoluteString) == [
            "http://192.168.1.10:8096",
            "https://192.168.1.10:8096"
        ])
    }

    @Test("Hostname with explicit port tries HTTP first")
    func hostnameWithPort() {
        let urls = JellyfinSignInViewModel.candidateURLs("media.local:8096")
        #expect(urls.first?.absoluteString == "http://media.local:8096")
    }

    @Test("Explicit scheme is trusted as-is")
    func explicitScheme() {
        #expect(JellyfinSignInViewModel.candidateURLs("https://jf.example.com").map(\.absoluteString) == ["https://jf.example.com"])
        #expect(JellyfinSignInViewModel.candidateURLs("http://10.0.0.5:8096").map(\.absoluteString) == ["http://10.0.0.5:8096"])
    }

    @Test("Trailing slash + whitespace are trimmed; empty yields nothing")
    func trimming() {
        #expect(JellyfinSignInViewModel.candidateURLs("  jellyfin.example.com/  ").first?.absoluteString == "https://jellyfin.example.com")
        #expect(JellyfinSignInViewModel.candidateURLs("   ").isEmpty)
    }
}
