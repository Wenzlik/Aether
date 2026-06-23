import SwiftUI
import AetherCore

/// Pick the SMB folders that make up the library (#214/#481). A custom two-level
/// flow in the app's design language:
///
/// 1. **Overview** — the folders you've chosen, each as a card showing its name,
///    path, what it contains (Movies & TV / Movies / TV Shows), and a Remove
///    action. An "Add Folder" button drops into the browser.
/// 2. **Browser** — drill through the server's shares and subfolders and add any
///    level; adding returns you to the overview so the selection is always in
///    view. Leaving the selection empty scans every share (original behaviour).
///
/// Native browse via `SMBSession` (the pure-Swift client) — same auth/errors as
/// the rest of SMB.
struct SMBFolderPickerView: View {
    let connection: SMBConnection
    @Binding var selectedRoots: [String]
    /// Per-root content choice, keyed by the root string. Defaulted so callers
    /// that don't track it still compile.
    @Binding var rootContent: [String: SMBRootContent]
    @Environment(\.dismiss) private var dismiss

    @State private var path: [SMBFolderLevelView.Location] = []

    init(connection: SMBConnection,
         selectedRoots: Binding<[String]>,
         rootContent: Binding<[String: SMBRootContent]> = .constant([:])) {
        self.connection = connection
        self._selectedRoots = selectedRoots
        self._rootContent = rootContent
    }

    var body: some View {
        NavigationStack(path: $path) {
            overview
                .navigationTitle("Library Folders")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .navigationDestination(for: SMBFolderLevelView.Location.self) { loc in
                    SMBFolderLevelView(
                        connection: connection,
                        location: loc,
                        selectedRoots: $selectedRoots,
                        onAdded: { path.removeAll() }   // pop back to the overview
                    )
                }
        }
    }

    // MARK: - Overview

    private var overview: some View {
        ZStack {
            LinearGradient(
                colors: [AetherDesign.Palette.background, AetherDesign.Palette.backgroundBottom],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                    if selectedRoots.isEmpty {
                        AetherEmptyState(
                            glyph: "folder.badge.plus",
                            title: "No folders yet",
                            message: "Add the folders that make up your library and tell Aether what each one holds. Leave it empty to scan every share on the server."
                        )
                        .padding(.top, AetherDesign.Spacing.l)
                    } else {
                        AetherSectionHeader(title: "Selected Folders")
                        VStack(spacing: AetherDesign.Spacing.s) {
                            ForEach(selectedRoots, id: \.self) { root in
                                SMBSelectedFolderCard(
                                    root: root,
                                    content: contentBinding(for: root),
                                    onRemove: { remove(root) }
                                )
                            }
                        }
                    }

                    Button { path.append(.shares) } label: {
                        AetherButtonLabel(title: "Add Folder", systemImage: "plus", role: .secondary)
                    }
                    .buttonStyle(.plain)

                    Text("Leave the selection empty to scan every share on this server.")
                        .font(AetherDesign.Typography.caption)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                        .padding(.horizontal, AetherDesign.Spacing.xs)
                }
                .padding(AetherDesign.Spacing.m)
            }
        }
    }

    // MARK: - Mutation

    private func remove(_ root: String) {
        selectedRoots.removeAll { $0 == root }
        rootContent[root] = nil
    }

    /// Binding for one root's content choice; absent ⇒ `.both` (auto-detect).
    private func contentBinding(for root: String) -> Binding<SMBRootContent> {
        Binding(
            get: { rootContent[root] ?? .both },
            set: { rootContent[root] = ($0 == .both ? nil : $0) }
        )
    }
}

// MARK: - Selected-folder card

/// One chosen folder: name, path, a segmented "Contains" control, and Remove.
private struct SMBSelectedFolderCard: View {
    let root: String
    @Binding var content: SMBRootContent
    let onRemove: () -> Void

    /// Folder display name = last path component; `root` is "share/sub/dir".
    private var name: String { root.split(separator: "/").last.map(String.init) ?? root }

    var body: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.s) {
            HStack(spacing: AetherDesign.Spacing.s) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(AetherDesign.Palette.accent)
                    .font(.system(size: 20))
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(AetherDesign.Typography.body.weight(.semibold))
                        .foregroundStyle(AetherDesign.Palette.textPrimary)
                        .lineLimit(1)
                    Text(root)
                        .font(AetherDesign.Typography.caption)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: AetherDesign.Spacing.s)
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(AetherDesign.Palette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove")
            }

            Picker("Contains", selection: $content) {
                Text("Movies & TV").tag(SMBRootContent.both)
                Text("Movies").tag(SMBRootContent.movies)
                Text("TV Shows").tag(SMBRootContent.series)
            }
            #if !os(tvOS)
            .pickerStyle(.segmented)
            #endif
        }
        .padding(AetherDesign.Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                .fill(AetherDesign.Palette.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                .strokeBorder(AetherDesign.Palette.separator, lineWidth: 1)
        )
    }
}

// MARK: - Browser

/// One directory level of the browser. `.shares` lists the server's shares;
/// `.directory` lists one folder's subdirectories and offers an Add toggle.
private struct SMBFolderLevelView: View {
    enum Location: Hashable {
        case shares
        /// A folder inside a share. `root` is the `share/path` string saved as a
        /// library root; `title` is the folder's display name.
        case directory(share: String, path: String, root: String, title: String)
    }

    let connection: SMBConnection
    let location: Location
    @Binding var selectedRoots: [String]
    /// Called after a folder is added, so the picker can return to the overview.
    var onAdded: () -> Void = {}

    @State private var folders: [SMBNativeEntry] = []
    @State private var shares: [String] = []
    @State private var phase: Phase = .loading

    private enum Phase: Equatable { case loading, loaded, failed(String) }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [AetherDesign.Palette.background, AetherDesign.Palette.backgroundBottom],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                    if case let .directory(_, _, root, _) = location {
                        addThisFolderButton(root)
                    }

                    switch phase {
                    case .loading:
                        HStack { Spacer(); ProgressView(); Spacer() }
                            .padding(.top, AetherDesign.Spacing.xl)
                    case .failed(let message):
                        Text(message)
                            .font(AetherDesign.Typography.caption)
                            .foregroundStyle(.red)
                    case .loaded:
                        folderList
                    }
                }
                .padding(AetherDesign.Spacing.m)
            }
        }
        .navigationTitle(levelTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
    }

    /// The prominent add/added control at a folder level — a filled accent pill
    /// when not yet added, a subtle "Added" card once it is.
    private func addThisFolderButton(_ root: String) -> some View {
        let added = isSelected(root)
        return Button { toggle(root) } label: {
            HStack(spacing: AetherDesign.Spacing.s) {
                Image(systemName: added ? "checkmark.circle.fill" : "plus.circle.fill")
                    .font(.system(size: 20))
                Text(added ? "Added to Library" : "Add This Folder")
                    .font(AetherDesign.Typography.body.weight(.semibold))
                Spacer()
            }
            .foregroundStyle(added ? AetherDesign.Palette.accent : Color.white)
            .padding(AetherDesign.Spacing.m)
            .background(
                RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                    .fill(added ? AetherDesign.Palette.surfaceElevated : AetherDesign.Palette.accent)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                    .strokeBorder(AetherDesign.Palette.separator, lineWidth: added ? 1 : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var folderList: some View {
        switch location {
        case .shares:
            if shares.isEmpty {
                emptyHint("No shares found on this server.")
            } else {
                browseContainer {
                    ForEach(Array(shares.enumerated()), id: \.element) { idx, share in
                        if idx > 0 { rowDivider }
                        browseLink(icon: "externaldrive.connected.to.line.below",
                                   name: share,
                                   to: childLocation(share: share, path: "", name: share))
                    }
                }
            }
        case .directory:
            if folders.isEmpty {
                emptyHint("No subfolders here.")
            } else {
                browseContainer {
                    ForEach(Array(folders.enumerated()), id: \.element) { idx, entry in
                        if idx > 0 { rowDivider }
                        browseLink(icon: "folder.fill",
                                   name: entry.name,
                                   to: childLocation(share: shareName, path: entry.path, name: entry.name))
                    }
                }
            }
        }
    }

    private func browseLink(icon: String, name: String, to location: Location) -> some View {
        NavigationLink(value: location) {
            HStack(spacing: AetherDesign.Spacing.s) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(AetherDesign.Palette.accent)
                    .frame(width: 26)
                Text(name)
                    .font(AetherDesign.Typography.body)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: AetherDesign.Spacing.s)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
            }
            .padding(.vertical, AetherDesign.Spacing.s)
            .padding(.horizontal, AetherDesign.Spacing.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func browseContainer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(
                RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                    .fill(AetherDesign.Palette.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                    .strokeBorder(AetherDesign.Palette.separator, lineWidth: 1)
            )
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(AetherDesign.Palette.separator)
            .frame(height: 1)
            .padding(.leading, AetherDesign.Spacing.m + 26)
    }

    private func emptyHint(_ text: String) -> some View {
        Text(LocalizedStringKey(text))
            .font(AetherDesign.Typography.caption)
            .foregroundStyle(AetherDesign.Palette.textSecondary)
    }

    // MARK: - Location helpers

    private var shareName: String {
        if case let .directory(share, _, _, _) = location { return share }
        return ""
    }

    private var levelTitle: String {
        switch location {
        case .shares: return "Add Folder"
        case .directory(_, _, _, let title): return title
        }
    }

    private func childLocation(share: String, path: String, name: String) -> Location {
        let root = path.isEmpty ? share : "\(share)/\(path)"
        return .directory(share: share, path: path, root: root, title: name)
    }

    // MARK: - Selection

    private func isSelected(_ root: String) -> Bool { selectedRoots.contains(root) }

    private func toggle(_ root: String) {
        if let index = selectedRoots.firstIndex(of: root) {
            selectedRoots.remove(at: index)
        } else {
            selectedRoots.append(root)
            onAdded()
        }
    }

    // MARK: - Load

    private func load() async {
        let session = SMBSession(connection: connection)
        switch location {
        case .shares:
            do {
                shares = try await session.shares().sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                phase = .loaded
            } catch {
                phase = .failed("Couldn't list shares.\n\n\(error.localizedDescription)")
            }
        case .directory(let share, let path, _, _):
            do {
                let entries = try await session.list(share: share, path: path)
                folders = entries.filter(\.isDirectory)
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                phase = .loaded
            } catch {
                phase = .failed("Couldn't open this folder.\n\n\(error.localizedDescription)")
            }
        }
    }
}
