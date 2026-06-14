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
        // Brand lockup as a leading titlebar accessory — sits right after the
        // traffic lights and before the sidebar toggle, with no button
        // background (a SwiftUI toolbar item gave a glass capsule + a duplicate
        // toggle). AppKit places accessories exactly where we want.
        .background(TitlebarLogo())
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

/// Places the AETHER brand mark as a **leading titlebar accessory** — after the
/// traffic lights and before the sidebar toggle, with no button background.
/// Idempotent: added once per window.
private struct TitlebarLogo: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let probe = NSView(frame: .zero)
        DispatchQueue.main.async {
            guard let window = probe.window else { return }
            let id = NSUserInterfaceItemIdentifier("AetherTitlebarLogo")
            guard !window.titlebarAccessoryViewControllers.contains(where: { $0.identifier == id }) else { return }
            let logo = Image("AetherBrandMark").resizable().scaledToFit()
                .frame(height: 16).padding(.horizontal, 8).padding(.vertical, 4)
            let host = NSHostingController(rootView: logo)
            host.view.frame = NSRect(x: 0, y: 0, width: 96, height: 28)
            let accessory = NSTitlebarAccessoryViewController()
            accessory.identifier = id
            accessory.layoutAttribute = .leading
            accessory.view = host.view
            window.addTitlebarAccessoryViewController(accessory)
        }
        return probe
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
