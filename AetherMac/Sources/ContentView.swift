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
    @State private var sidebar: SidebarItem? = .home
    @State private var searchText = ""

    enum SidebarItem: Hashable, Identifiable {
        case home, discover, library, search
        var id: Self { self }
    }

    var body: some View {
        NavigationSplitView {
            sidebarList
                .navigationSplitViewColumnWidth(min: 210, ideal: 230)
        } detail: {
            detail
        }
        .environment(\.watchedDisplay, session.playbackPrefs.watchedDisplayConfig)
        .task { await session.restore() }
        // Finder "Open With ▸ Aether" / double-click on a registered video type.
        .onOpenURL { url in openLocal(url) }
        // Drag a video file onto the window to play it.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            openLocal(url)
            return true
        }
        // The player lives **inside** this window, presented over everything,
        // rather than spawning a separate window.
        .overlay {
            if let url = session.playbackURL {
                MpvPlayerScreen(
                    url: url,
                    session: session,
                    item: session.item(forPlaybackURL: url),
                    onClose: { session.stopPlayback() }
                )
                .id(url)                       // fresh player per title
                .ignoresSafeArea()
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: session.playbackURL)
    }

    // MARK: Sidebar

    private var sidebarList: some View {
        List(selection: $sidebar) {
            Label("Home", systemImage: "house").tag(SidebarItem.home)
            Label("Discover", systemImage: "sparkles").tag(SidebarItem.discover)
            Label("Library", systemImage: "square.grid.2x2").tag(SidebarItem.library)
            Label("Search", systemImage: "magnifyingglass").tag(SidebarItem.search)
            // Settings opens the native Settings window (⌘,), not an in-pane view —
            // connecting / managing Plex & Jellyfin lives there.
            SettingsLink { Label("Settings", systemImage: "gearshape") }
                .buttonStyle(.plain)
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        NavigationStack {
            Group {
                switch sidebar {
                case .library:  LibraryGridView(session: session)
                case .discover: DiscoverView(session: session, mode: .discover)
                case .search:   searchPane
                default:        DiscoverView(session: session, mode: .home)
                }
            }
            .navigationDestination(for: MediaItem.self) { mediaItem in
                MediaDetailView(session: session, item: mediaItem, onPlay: playServerItem)
            }
        }
    }

    private var searchPane: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search your library", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(20)
            MacSearchResults(session: session, query: searchText)
        }
        .navigationTitle("Search")
    }

    // MARK: Open

    private func openLocal(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        recents.add(url)
        session.playLocal(url)
    }

    private func playServerItem(_ item: MediaItem) {
        Task { await session.play(item) }
    }

    static var videoTypes: [UTType] {
        var types: [UTType] = [.movie, .video, .audiovisualContent, .mpeg4Movie, .quickTimeMovie]
        for ext in ["mkv", "avi", "ts", "m2ts", "webm"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }
}
