import SwiftUI
import AetherCore

@main
struct AetherApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView(source: MockMediaSource())
                .preferredColorScheme(.dark)
                .tint(AetherDesign.Palette.accent)
        }
    }
}
