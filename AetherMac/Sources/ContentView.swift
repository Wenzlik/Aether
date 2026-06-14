import SwiftUI
import UniformTypeIdentifiers

/// Open-a-video shell: a welcome state with an Open button, swapped for the VLC
/// player once a file is picked. The system window frames the player (resize /
/// full-screen / ⌘W come free).
struct ContentView: View {
    @State private var videoURL: URL?
    @State private var isImporting = false

    var body: some View {
        Group {
            if let videoURL {
                VLCMacPlayerView(url: videoURL)
                    .ignoresSafeArea()
            } else {
                welcome
            }
        }
        .toolbar {
            ToolbarItem {
                Button { isImporting = true } label: {
                    Label("Open…", systemImage: "folder")
                }
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: Self.videoTypes,
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            // Dev slice isn't sandboxed; start-access is harmless now and the
            // right call once the App Store sandbox + bookmarks land (#232).
            _ = url.startAccessingSecurityScopedResource()
            videoURL = url
        }
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
            Text("Open a video to play")
                .font(.title2)
            Text("MKV, MP4, MOV, and more — played with VLCKit (DTS, multi-track).")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open…") { isImporting = true }
                .keyboardShortcut("o")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    /// Video UTTypes the picker accepts, plus dynamic types for containers
    /// without a built-in UTI (mkv / avi / ts) so they're still selectable —
    /// mirrors the iOS Local Library importer.
    static var videoTypes: [UTType] {
        var types: [UTType] = [.movie, .video, .audiovisualContent, .mpeg4Movie, .quickTimeMovie]
        for ext in ["mkv", "avi", "ts", "m2ts", "webm"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }
}
