import SwiftUI

/// Native macOS Aether (#232) — player-first. This vertical slice opens a video
/// file and plays it via VLCKit (MKV/DTS/multi-track), reusing the same engine
/// as iOS. Finder file-association, play-in-place, and the rich player window
/// are the next steps; this proves the native-macOS target + VLCKit `macos`
/// slice build and play.
@main
struct AetherMacApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 720, minHeight: 450)
        }
    }
}
