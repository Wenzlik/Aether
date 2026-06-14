import SwiftUI
import UniformTypeIdentifiers

/// Infuse-style home: a sidebar (Library + Sources) and a content area. Today
/// the content is the local-file experience (Recent + Open); the Sources rows
/// are placeholders that show where Plex / Jellyfin / SMB / Local plug in once a
/// Mac session lands (#232). Opening a file spawns a player window.
struct HomeView: View {
    var recents: RecentsStore
    @Environment(\.openWindow) private var openWindow
    @State private var isImporting = false
    @State private var sidebar: SidebarItem? = .home

    enum SidebarItem: Hashable, Identifiable {
        case home
        var id: Self { self }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $sidebar) {
                Section("Library") {
                    Label("Home", systemImage: "house").tag(SidebarItem.home)
                    Button {
                        isImporting = true
                    } label: {
                        Label("Open File…", systemImage: "folder")
                    }
                    .buttonStyle(.plain)
                }
                Section("Sources") {
                    sourceRow("Plex", "play.rectangle.on.rectangle")
                    sourceRow("Jellyfin", "play.tv")
                    sourceRow("SMB / NAS", "externaldrive.connected.to.line.below")
                    sourceRow("Local Library", "internaldrive")
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            content
                .toolbar {
                    ToolbarItem {
                        Button { isImporting = true } label: { Label("Open…", systemImage: "folder") }
                            .keyboardShortcut("o")
                    }
                }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: Self.videoTypes,
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            open(url)
        }
        // Finder "Open With ▸ Aether" / double-click on a registered video type
        // (#232) → straight to a player window.
        .onOpenURL { url in open(url) }
        // Drag a video file onto the window to play it — Mac-native.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            open(url)
            return true
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if recents.urls.isEmpty {
            welcome
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 20)], spacing: 20) {
                    ForEach(recents.urls, id: \.self) { url in
                        Button { open(url) } label: { fileCard(url) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(24)
            }
            .navigationTitle("Recent")
        }
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.secondary)
            Text("Open a video to play")
                .font(.title)
            Text("MKV, MP4, MOV, and more — played with VLCKit (DTS, multi-track).")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open…") { isImporting = true }
                .controlSize(.large)
                .keyboardShortcut("o")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .navigationTitle("Aether")
    }

    private func fileCard(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.quaternary)
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                Image(systemName: "film")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.secondary)
            }
            Text(url.deletingPathExtension().lastPathComponent)
                .font(.callout)
                .lineLimit(2)
                .foregroundStyle(.primary)
            Text(url.pathExtension.uppercased())
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func sourceRow(_ title: String, _ symbol: String) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                Text("Soon").font(.caption2).foregroundStyle(.tertiary)
            }
        } icon: {
            Image(systemName: symbol)
        }
        .foregroundStyle(.secondary)
    }

    // MARK: Open

    private func open(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        recents.add(url)
        openWindow(value: url)
    }

    static var videoTypes: [UTType] {
        var types: [UTType] = [.movie, .video, .audiovisualContent, .mpeg4Movie, .quickTimeMovie]
        for ext in ["mkv", "avi", "ts", "m2ts", "webm"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }
}
