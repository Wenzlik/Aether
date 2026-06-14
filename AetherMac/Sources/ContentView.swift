import SwiftUI
import AetherCore
import UniformTypeIdentifiers

/// Infuse-style home: a sidebar (Library + Sources) and a content area. With a
/// server connected it shows the unified library; otherwise the local-file
/// experience (Recent + Open). Opening a file or a library item spawns the right
/// player window (AVPlayer for native formats, VLCKit for mkv/DTS).
struct HomeView: View {
    var session: MacSession
    var recents: RecentsStore
    @Environment(\.openWindow) private var openWindow
    @State private var isImporting = false
    @State private var sidebar: SidebarItem? = .home
    @State private var signIn: SignInTarget?

    enum SidebarItem: Hashable, Identifiable {
        case home
        var id: Self { self }
    }
    enum SignInTarget: String, Identifiable {
        case plex, jellyfin
        var id: String { rawValue }
    }

    var body: some View {
        NavigationSplitView {
            sidebarList
                .navigationSplitViewColumnWidth(min: 210, ideal: 230)
        } detail: {
            detail
                .toolbar {
                    ToolbarItem {
                        Button { isImporting = true } label: { Label("Open…", systemImage: "folder") }
                            .keyboardShortcut("o")
                    }
                }
        }
        .task { await session.restore() }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: Self.videoTypes,
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            openLocal(url)
        }
        // Finder "Open With ▸ Aether" / double-click on a registered video type.
        .onOpenURL { url in openLocal(url) }
        // Drag a video file onto the window to play it.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            openLocal(url)
            return true
        }
        .sheet(item: $signIn) { target in
            switch target {
            case .plex:     PlexSignInSheet(session: session) { signIn = nil }
            case .jellyfin: JellyfinSignInSheet(session: session) { signIn = nil }
            }
        }
    }

    // MARK: Sidebar

    private var sidebarList: some View {
        List(selection: $sidebar) {
            Section("Library") {
                Label("Home", systemImage: "house").tag(SidebarItem.home)
                Button { isImporting = true } label: {
                    Label("Open File…", systemImage: "folder")
                }
                .buttonStyle(.plain)
            }
            Section("Sources") {
                if session.isPlexConnected {
                    Label("Plex", systemImage: "play.rectangle.on.rectangle")
                } else {
                    connectRow("Plex", "play.rectangle.on.rectangle") { signIn = .plex }
                }
                if session.isJellyfinConnected {
                    Label("Jellyfin", systemImage: "play.tv")
                } else {
                    connectRow("Jellyfin", "play.tv") { signIn = .jellyfin }
                }
                soonRow("SMB / NAS", "externaldrive.connected.to.line.below")
                soonRow("Local Library", "internaldrive")
            }
        }
    }

    private func connectRow(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                HStack {
                    Text(title)
                    Spacer()
                    Text("Connect").font(.caption2).foregroundStyle(.tint)
                }
            } icon: { Image(systemName: symbol) }
        }
        .buttonStyle(.plain)
    }

    private func soonRow(_ title: String, _ symbol: String) -> some View {
        Label {
            HStack { Text(title); Spacer(); Text("Soon").font(.caption2).foregroundStyle(.tertiary) }
        } icon: { Image(systemName: symbol) }
        .foregroundStyle(.secondary)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if session.hasAnySource {
            NavigationStack {
                LibraryGridView(session: session)
                    .navigationDestination(for: MediaItem.self) { mediaItem in
                        MediaDetailView(session: session, item: mediaItem, onPlay: playServerItem)
                    }
            }
        } else if recents.urls.isEmpty {
            welcome
        } else {
            recentsGrid
        }
    }

    private var recentsGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 20)], spacing: 20) {
                ForEach(recents.urls, id: \.self) { url in
                    Button { openLocal(url) } label: { fileCard(url) }
                        .buttonStyle(.plain)
                }
            }
            .padding(24)
        }
        .navigationTitle("Recent")
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.secondary)
            Text("Open a video to play")
                .font(.title)
            Text("Open a local file, or connect Plex / Jellyfin from the sidebar.")
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
                .font(.callout).lineLimit(2).foregroundStyle(.primary)
            Text(url.pathExtension.uppercased())
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Open

    private func openLocal(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        recents.add(url)
        openWindow(value: url)
    }

    private func playServerItem(_ item: MediaItem) {
        Task {
            if let url = await session.resolvedURL(for: item) {
                openWindow(value: url)
            }
        }
    }

    static var videoTypes: [UTType] {
        var types: [UTType] = [.movie, .video, .audiovisualContent, .mpeg4Movie, .quickTimeMovie]
        for ext in ["mkv", "avi", "ts", "m2ts", "webm"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }
}
