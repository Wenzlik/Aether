import SwiftUI
import AppKit
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
        case home, discover, library, search, settings
        var id: Self { self }
    }

    var body: some View {
        // The player **replaces** the library in the same window while playing
        // (a true swap, not an overlay/ZStack) so the navigation chrome —
        // toolbar, sidebar toggle, back button, window title — isn't in the
        // hierarchy at all. Overlaying left that chrome rendering in the
        // titlebar, which duplicated the title and the back arrow.
        Group {
            if let url = session.playbackURL {
                MpvPlayerScreen(
                    url: url,
                    session: session,
                    item: session.item(forPlaybackURL: url),
                    onClose: { session.stopPlayback() }
                )
                .id(url)                       // fresh player per title
                .ignoresSafeArea()
            } else {
                library
            }
        }
        .tint(AetherMacTheme.accent)
        .preferredColorScheme(.dark)
        .environment(\.locale, session.appLocale)
    }

    private var library: some View {
        NavigationSplitView {
            sidebarList
                .navigationSplitViewColumnWidth(min: 210, ideal: 230)
        } detail: {
            detail
        }
        // Brand lockup in the titlebar, immediately left of the sidebar toggle.
        // We drop the automatic toggle and re-add our own *after* the logo so the
        // order is: traffic lights → AETHER → toggle. The logo is a plain image
        // (no toolbar-button background).
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Image("AetherBrandMark").resizable().scaledToFit().frame(height: 16)
            }
            ToolbarItem(placement: .navigation) {
                Button { toggleSidebar() } label: { Image(systemName: "sidebar.left") }
            }
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
    }

    // MARK: Sidebar

    private var sidebarList: some View {
        List(selection: $sidebar) {
            Label("Home", systemImage: "house").tag(SidebarItem.home)
            Label("Discover", systemImage: "sparkles").tag(SidebarItem.discover)
            Label("Library", systemImage: "square.grid.2x2").tag(SidebarItem.library)
            Label("Search", systemImage: "magnifyingglass").tag(SidebarItem.search)
            // Settings opens inside this window (detail pane), not a separate window.
            Label("Settings", systemImage: "gearshape").tag(SidebarItem.settings)
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
                case .settings: MacSettingsView(session: session, embedded: true)
                default:        DiscoverView(session: session, mode: .home)
                }
            }
            .navigationDestination(for: MediaItem.self) { mediaItem in
                MediaDetailView(session: session, item: mediaItem, onPlay: playServerItem)
            }
            .navigationDestination(for: LibraryRoute.self) { route in
                LibraryBrowseView(session: session, route: route)
            }
        }
    }

    private var searchPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search your library", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.title3)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 24)
            .padding(.top, 20)

            if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                AetherEmptyState(
                    glyph: "magnifyingglass",
                    title: "Search your library",
                    message: "Find movies and shows across your connected sources."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MacSearchResults(session: session, query: searchText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .cinematicBackground()
        .navigationTitle("Search")
    }

    // MARK: Open

    /// Toggle the split view's sidebar (we replaced the system toggle so the
    /// logo can sit to its left).
    private func toggleSidebar() {
        NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
    }

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
