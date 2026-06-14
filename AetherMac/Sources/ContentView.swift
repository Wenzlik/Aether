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
    /// The detail-pane navigation path, lifted to `HomeView` so it **survives the
    /// player swap** — playback replaces the whole library subtree, so a path
    /// owned by the `NavigationStack` would reset to root on close. Keeping it
    /// here returns the user to the title's Detail after playback (#8).
    @State private var path = NavigationPath()

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
        .preferredColorScheme(session.appearance.preference.colorScheme)
        .environment(\.locale, session.appLocale)
    }

    private var library: some View {
        NavigationSplitView {
            sidebarList
                .navigationSplitViewColumnWidth(min: 210, ideal: 230)
                // Drop the system's automatic sidebar toggle — it drifted to the
                // far top-right of the unified toolbar once a leading titlebar
                // accessory was present (#14). We render our own toggle inside the
                // leading accessory instead, so logo + toggle sit together by the
                // traffic lights. (A SwiftUI custom toggle here previously caused a
                // *duplicate*; placing it in the AppKit accessory avoids that.)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
        }
        // Leading titlebar accessory: the brand lockup + the sidebar toggle, right
        // after the traffic lights, no button background. AppKit places it exactly.
        .background(TitlebarLeadingAccessory())
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
        NavigationStack(path: $path) {
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

/// The AETHER brand mark **plus** a sidebar toggle as a single **leading
/// titlebar accessory** — after the traffic lights, no button background. The
/// system's own toggle is removed (`.toolbar(removing: .sidebarToggle)`) so this
/// is the only one, and logo + toggle stay together at the leading edge.
///
/// This rides on the **library** view, which the inline player replaces during
/// playback. The accessory is a *window*-level object, so it would otherwise
/// linger over the full-bleed player and overlap its own back button + title —
/// so we hide it when this representable is torn down (playback start) and show
/// it again when the library returns. Idempotent: one accessory per window.
private struct TitlebarLeadingAccessory: NSViewRepresentable {
    private static let id = NSUserInterfaceItemIdentifier("AetherTitlebarLeading")

    final class Coordinator { weak var accessory: NSTitlebarAccessoryViewController? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let probe = NSView(frame: .zero)
        DispatchQueue.main.async {
            guard let window = probe.window else { return }
            if let existing = window.titlebarAccessoryViewControllers.first(where: { $0.identifier == Self.id }) {
                existing.isHidden = false               // library returned after playback
                context.coordinator.accessory = existing
                return
            }
            let content = HStack(spacing: 8) {
                Image("AetherBrandMark").resizable().interpolation(.high).scaledToFit()
                    .frame(height: 20)
                SidebarToggleButton()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            let host = NSHostingController(rootView: content)
            // Size to the content's natural aspect — a fixed width squished
            // "AETHER" horizontally, which read as a broken/blurry logo.
            host.view.frame.size = host.view.fittingSize
            let accessory = NSTitlebarAccessoryViewController()
            accessory.identifier = Self.id
            accessory.layoutAttribute = .leading
            accessory.view = host.view
            window.addTitlebarAccessoryViewController(accessory)
            context.coordinator.accessory = accessory
        }
        return probe
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    /// Hide the accessory when the library is swapped out for the player, so it
    /// doesn't float over the full-bleed player and hide its back button/title.
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.accessory?.isHidden = true
    }
}

/// A borderless sidebar toggle that drives AppKit's standard `toggleSidebar(_:)`
/// up the responder chain (the NavigationSplitView is bridged to an
/// `NSSplitViewController`, which implements it) — so collapsing the sidebar
/// works without re-adding the system toggle we removed.
private struct SidebarToggleButton: View {
    var body: some View {
        Button {
            NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
        } label: {
            Image(systemName: "sidebar.leading")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Toggle Sidebar")
    }
}
