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
    var appDelegate: MacAppDelegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismissWindow
    @State private var searchText = ""
    /// The detail-pane navigation path, lifted to `HomeView` so it **survives the
    /// player swap** — playback replaces the whole library subtree, so a path
    /// owned by the `NavigationStack` would reset to root on close. Keeping it
    /// here returns the user to the title's Detail after playback (#8).
    @State private var path = NavigationPath()

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
                // Player is in the window now → strip the title + leading
                // accessory so they don't float over the full-bleed video.
                .background(PlayerTitlebar())
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
        // Library is in the window → ensure the leading logo+toggle accessory is
        // present and the title visible. (Reliably attaches, unlike a Group-level
        // probe; the player strips them again via PlayerTitlebar.)
        .background(LibraryTitlebar())
        .environment(\.watchedDisplay, session.playbackPrefs.watchedDisplayConfig)
        .task { await session.restore() }
        // Finder "Open With ▸ Aether" / double-click on a registered video type.
        // On a *launch* open (app was closed), drop this auto-created library
        // window so only the player window remains; it reopens on the next Dock
        // activation. Opening a file while browsing keeps the library.
        .onOpenURL { url in
            openLocal(url)
            if appDelegate.isColdLaunch { dismissWindow() }
        }
        // Drag a video file onto the window to play it.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            openLocal(url)
            return true
        }
    }

    // MARK: Sidebar

    private var sidebarList: some View {
        // Rows + selection both derive from `MacSession.Section`, the same source
        // the menu-bar View commands use — so a ⌘1…⌘5 pick highlights the right
        // row and vice-versa. (Settings opens in this window's detail pane, not
        // the separate native Settings window.)
        List(selection: sectionSelection) {
            ForEach(MacSession.Section.allCases) { section in
                Label(section.title, systemImage: section.symbol).tag(section)
            }
        }
    }

    /// Bridges the List's optional single-selection to `session.section` (the
    /// non-optional source of truth). A `nil` from the List — a click in empty
    /// space — is ignored, so the detail pane never goes blank.
    private var sectionSelection: Binding<MacSession.Section?> {
        Binding(
            get: { session.section },
            set: { if let new = $0 { session.section = new } }
        )
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        NavigationStack(path: $path) {
            Group {
                switch session.section {
                case .home:     DiscoverView(session: session, mode: .home)
                case .discover: DiscoverView(session: session, mode: .discover)
                case .library:  LibraryGridView(session: session)
                case .search:   searchPane
                case .settings: MacSettingsView(session: session, embedded: true)
                }
            }
            // Give each section a stable identity so switching panes fully
            // replaces the view — otherwise the previous pane's title/toolbar can
            // linger in the titlebar (the stray "Settings" + gear over the traffic
            // lights when switching to Search, #432).
            .id(session.section)
            .navigationDestination(for: MediaItem.self) { mediaItem in
                MediaDetailView(session: session, item: mediaItem, onPlay: playServerItem)
            }
            .navigationDestination(for: LibraryRoute.self) { route in
                LibraryBrowseView(session: session, route: route)
            }
        }
    }

    private var searchPane: some View {
        // The custom in-content field didn't reliably render under the unified
        // titlebar (#432); use the native search field, which macOS places in the
        // toolbar and which is always visible.
        Group {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cinematicBackground()
        .navigationTitle("Search")
        .searchable(text: $searchText, placement: .toolbar, prompt: Text("Search your library"))
    }

    // MARK: Open

    private func openLocal(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        recents.add(url)
        // Ad-hoc disk files play in their own window (not inline over the
        // library) — see AetherMacApp's local-player WindowGroup (#232 follow-up).
        openWindow(id: AetherMacApp.localPlayerWindowID, value: url)
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
private let aetherTitlebarAccessoryID = NSUserInterfaceItemIdentifier("AetherTitlebarLeading")

/// Builds the leading sidebar-toggle titlebar accessory (no button background).
/// The AETHER wordmark was removed from here (#432): a leading accessory sits in
/// the zone the window's traffic-light controls own, so the brand mark collided /
/// garbled with them. Only the sidebar toggle — a control that belongs by the
/// traffic lights — remains.
private func makeAetherTitlebarAccessory() -> NSTitlebarAccessoryViewController {
    let content = SidebarToggleButton()
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    let host = NSHostingController(rootView: content)
    host.view.frame.size = host.view.fittingSize
    let accessory = NSTitlebarAccessoryViewController()
    accessory.identifier = aetherTitlebarAccessoryID
    accessory.layoutAttribute = .leading
    accessory.view = host.view
    return accessory
}

/// Rides on the **library** view (which reliably attaches to the window): ensures
/// the leading logo+toggle accessory is present and the window title is visible.
/// Idempotent — re-runs when the library reappears after playback, restoring the
/// chrome the player stripped.
private struct LibraryTitlebar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let probe = NSView(frame: .zero)
        DispatchQueue.main.async {
            guard let window = probe.window else { return }
            window.titleVisibility = .visible
            window.titlebarSeparatorStyle = .automatic
            if !window.titlebarAccessoryViewControllers.contains(where: { $0.identifier == aetherTitlebarAccessoryID }) {
                window.addTitlebarAccessoryViewController(makeAetherTitlebarAccessory())
            }
        }
        return probe
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Rides on the **player** view: removes the leading accessory and hides the
/// window title + separator, so nothing floats over the full-bleed video or
/// collides with the player's own back button + title. `LibraryTitlebar` restores
/// them when the library returns.
private struct PlayerTitlebar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let probe = NSView(frame: .zero)
        DispatchQueue.main.async {
            guard let window = probe.window else { return }
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            if let index = window.titlebarAccessoryViewControllers.firstIndex(where: { $0.identifier == aetherTitlebarAccessoryID }) {
                window.removeTitlebarAccessoryViewController(at: index)
            }
        }
        return probe
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
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
