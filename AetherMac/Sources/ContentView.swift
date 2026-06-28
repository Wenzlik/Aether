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
    /// Ask Aether answer (library matches + optional recommendation), shown after
    /// the user submits a request. Sticky while refining; dropped when cleared.
    @State private var askResult: AskResult?
    /// On-device inference in flight.
    @State private var isAsking = false
    /// Drives sidebar collapse state — SwiftUI writes this when the split view
    /// collapses the sidebar column (e.g. sidebar toggle or window resize).
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var showDownloads = false
    /// True when the sidebar is fully hidden (no column visible).
    private var sidebarCollapsed: Bool { columnVisibility == .detailOnly }
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
                // No .ignoresSafeArea() here — Color.black and MpvVideoView
                // inside the ZStack each carry their own .ignoresSafeArea() and
                // fill the full window. Keeping the safe-area context on the
                // outer view means the VStack with the back button starts below
                // the macOS titlebar instead of under the traffic lights.
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
        // Infuse-style animated mark on cold launch (shown once per process).
        .macLaunchSplash()
    }

    private var library: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
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
        // When the sidebar is collapsed the user has no visible navigation — show
        // compact icon+label tabs in the toolbar as a replacement. Fades in/out
        // with the sidebar so there's never a moment with no navigation at all.
        .toolbar {
            ToolbarItem(placement: .principal) {
                if sidebarCollapsed {
                    SectionTabBar(session: session)
                        .transition(.opacity.combined(with: .scale(0.92)))
                }
            }
            // Downloads button — trailing side of the toolbar. Badge shows the
            // count of in-progress jobs so the user sees activity at a glance.
            ToolbarItem(placement: .automatic) {
                let snapshot = session.downloadObserver?.snapshot ?? .empty
                let hasAny = !snapshot.inProgress.isEmpty || !snapshot.completed.isEmpty
                if hasAny {
                    Button {
                        showDownloads.toggle()
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 14, weight: .medium))
                            if !snapshot.inProgress.isEmpty {
                                Circle()
                                    .fill(AetherMacTheme.accent)
                                    .frame(width: 8, height: 8)
                                    .offset(x: 4, y: -4)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Downloads")
                    .popover(isPresented: $showDownloads, arrowEdge: .top) {
                        DownloadsView(session: session)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: sidebarCollapsed)
        .environment(\.watchedDisplay, session.playbackPrefs.watchedDisplayConfig)
        .environment(\.posterRatingSource, session.playbackPrefs.posterRatingSource)
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
        VStack(spacing: 0) {
            // Infuse-style search field at the top of the sidebar; typing surfaces
            // results over the current pane (see `detail`). Search is no longer a
            // section — it lives here, always reachable.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Ask Aether…", text: $searchText)
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await ask() } }
                    .onChange(of: searchText) { _, v in
                        if v.trimmingCharacters(in: .whitespaces).isEmpty { askResult = nil }
                    }
                if !searchText.isEmpty {
                    Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)

            // Rows + selection both derive from `MacSession.Section`, the same
            // source the menu-bar View commands use — so a ⌘1…⌘4 pick highlights
            // the right row and vice-versa. (Settings opens in this window's
            // detail pane, not the separate native Settings window.)
            List(selection: sectionSelection) {
                ForEach(MacSession.Section.allCases) { section in
                    Label(section.title, systemImage: section.symbol).tag(section)
                }
            }
            // Explicit tint on the List ensures the selected-row pill renders in
            // Aether Blue even when the user's macOS system accent is a different
            // colour — `.tint()` on the parent Group doesn't always propagate
            // through NavigationSplitView to the NSTableView-backed sidebar row.
            .tint(AetherMacTheme.accent)
        }
        // Explicit sidebar vibrancy: .behindWindow blending so the sidebar
        // translucency shows the desktop (or other windows) through it regardless
        // of the user's wallpaper. SwiftUI sets this on NavigationSplitView's
        // sidebar column automatically, but naming it explicitly here ensures the
        // NSVisualEffectView is always `.active` and uses the `.sidebar` material
        // rather than defaulting to `.windowBackground` on some macOS versions.
        .background(SidebarVibrancyBackground())
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
                if isAsking {
                    ProgressView("Asking Aether…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .cinematicBackground()
                        .navigationTitle("Ask Aether")
                } else if let askResult {
                    MacAskResults(session: session, result: askResult, pendingQuery: askPending)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .cinematicBackground()
                        .navigationTitle("Ask Aether")
                } else if isSearching {
                    // Typing in the sidebar field surfaces unified results over
                    // whatever section is selected; Return runs an Ask Aether request.
                    MacSearchResults(session: session, query: searchText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .cinematicBackground()
                        .navigationTitle("Search")
                } else {
                    switch session.section {
                    case .home:     DiscoverView(session: session, mode: .home)
                    case .discover: DiscoverView(session: session, mode: .discover)
                    case .library:  LibraryGridView(session: session)
                    }
                }
            }
            // Stable identity per pane (incl. the search / ask overlays) so
            // switching fully replaces the view — otherwise the previous pane's
            // title/toolbar lingers in the titlebar (the stray "Settings" + gear
            // over the traffic lights, #432).
            .id(askPaneID)
            .navigationDestination(for: MediaItem.self) { mediaItem in
                MediaDetailView(session: session, item: mediaItem, onPlay: playServerItem)
            }
            .navigationDestination(for: UnifiedMediaItem.self) { unified in
                let base = unified.preferredSource?.item ?? unified.sources.first!.item
                MediaDetailView(
                    session: session, item: base,
                    allSources: unified.sources,
                    onPlay: playServerItem
                )
            }
            .navigationDestination(for: LibraryRoute.self) { route in
                LibraryBrowseView(session: session, kind: route.kind)
            }
        }
    }

    /// Whether the sidebar search field has a query — drives the search overlay.
    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Stable identity for the detail pane across discovery / search / ask states.
    private var askPaneID: AnyHashable {
        if isAsking || askResult != nil { return AnyHashable("ask") }
        return isSearching ? AnyHashable("search") : AnyHashable(session.section)
    }

    /// Run an Ask Aether request from the sidebar field. Mirrors iOS.
    private func ask() async {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, session.hasAnySource, !isAsking else { return }
        isAsking = true
        defer { isAsking = false }
        let answer = await AskAether.answer(
            query: trimmed, sources: session.connectedSources, tmdb: session.tmdbClient
        )
        guard searchText.trimmingCharacters(in: .whitespaces) == trimmed else { return }
        askResult = answer
    }

    /// Edited-but-not-resubmitted request → "press Return to ask" hint.
    private var askPending: String? {
        guard let askResult else { return nil }
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        return (!trimmed.isEmpty && trimmed != askResult.query) ? trimmed : nil
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
            window.titlebarSeparatorStyle = .none
            window.title = "Aether"
            // fullSizeContentView extends the sidebar under the titlebar so it
            // reads as one seamless surface — the defining signal of a modern Mac
            // app (Infuse, Linear, Bear all use this). Transparent titlebar lets
            // the sidebar material show through the traffic-light zone.
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
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

/// Compact navigation shown in the toolbar when the sidebar is collapsed.
/// Sidebar toggle on the left, then icon+label tabs for the 3 sections.
private struct SectionTabBar: View {
    var session: MacSession

    var body: some View {
        HStack(spacing: 4) {
            // Sidebar re-open toggle.
            Button {
                NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
            } label: {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Show Sidebar")

            Divider().frame(height: 18).padding(.horizontal, 2)

            // Text-only pill tabs — no icons.
            ForEach(MacSession.Section.allCases) { section in
                Button { session.section = section } label: {
                    Text(section.title)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .foregroundStyle(session.section == section ? .white : Color.primary)
                        .background(
                            session.section == section ? AetherMacTheme.accent : Color.clear,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .help(section.title)
            }
        }
        .padding(5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// An NSVisualEffectView with `.sidebar` material and `.behindWindow` blending
/// used as the sidebar column background — ensures translucency against the
/// desktop / behind-window content regardless of the macOS version.
private struct SidebarVibrancyBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
