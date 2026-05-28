import SwiftUI
import AetherCore

@main
struct AetherApp: App {
    @State private var session = AppSession()

    var body: some Scene {
        WindowGroup {
            RootView(session: session)
                .preferredColorScheme(.dark)
                .tint(AetherDesign.Palette.accent)
                .task { await session.start() }
        }
    }
}

/// Owns the long-lived app-wide dependencies: the active media source, the
/// resume store, and the single playback session.
///
/// In 0.1 this loads the mock library. In 0.2 it will also wire up Plex and
/// Synology sources once they exist.
@MainActor
@Observable
final class AppSession {
    var source: (any MediaSource)?
    let resumeStore: ResumeStore
    let playback: PlaybackSession
    var loadError: String?

    init() {
        let store = ResumeStore()
        self.resumeStore = store
        self.playback = PlaybackSession(resumeStore: store)
    }

    func start() async {
        do {
            let mock = try MockMediaSource.loadFromBundle()
            // Seed resume store from the fixture so Continue Watching has content on first launch.
            for point in await mock.simulatedResumePoints {
                await resumeStore.record(point)
            }
            source = mock
        } catch {
            source = MockMediaSource()
            loadError = "Couldn't load MockLibrary.json — using built-in sample. (\(error.localizedDescription))"
        }
    }
}

private struct RootView: View {
    let session: AppSession

    var body: some View {
        if let source = session.source {
            HomeView(
                source: source,
                resumeStore: session.resumeStore,
                playbackSession: session.playback
            )
        } else {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
                Text("Aether")
                    .font(AetherDesign.Typography.heroTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
            }
            .padding(AetherDesign.Spacing.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(AetherDesign.Palette.background.ignoresSafeArea())
        }
    }
}
