import SwiftUI
import AetherCore

/// Browse an SMB server and pick **multiple** folders to include in the library
/// (#214 follow-up). Starts at the server's shares; tap a folder to drill in,
/// and "Add This Folder" at any level adds its `share/path` to the selection.
/// Leaving the selection empty scans every share (the original behaviour).
///
/// Native browse via `SMBSession` (the pure-Swift client) — same auth/errors as
/// the rest of SMB. Each level lists lazily in `.task`.
struct SMBFolderPickerView: View {
    let connection: SMBConnection
    @Binding var selectedRoots: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SMBFolderLevelView(
                connection: connection,
                location: .shares,
                selectedRoots: $selectedRoots
            )
            .navigationTitle("Choose Folders")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: SMBFolderLevelView.Location.self) { loc in
                SMBFolderLevelView(connection: connection, location: loc, selectedRoots: $selectedRoots)
            }
        }
    }
}

/// One directory level in the picker. `.shares` lists the server's shares;
/// `.directory` lists one folder's subdirectories and offers an "Add" toggle.
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

    @State private var folders: [SMBNativeEntry] = []
    @State private var shares: [String] = []
    @State private var phase: Phase = .loading

    private enum Phase: Equatable { case loading, loaded, failed(String) }

    var body: some View {
        List {
            if case let .directory(_, _, root, _) = location {
                Section {
                    Button {
                        toggle(root)
                    } label: {
                        HStack {
                            Image(systemName: isSelected(root) ? "checkmark.circle.fill" : "plus.circle")
                                .foregroundStyle(isSelected(root) ? AetherDesign.Palette.accent : .secondary)
                            Text(isSelected(root) ? "Added to Library" : "Add This Folder")
                            Spacer()
                        }
                    }
                }
            }

            switch phase {
            case .loading:
                HStack { Spacer(); ProgressView(); Spacer() }
            case .failed(let message):
                Text(message).foregroundStyle(.red).font(.footnote)
            case .loaded:
                folderRows
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .navigationTitle(levelTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
    }

    @ViewBuilder private var folderRows: some View {
        switch location {
        case .shares:
            if shares.isEmpty {
                Text("No shares found on this server.").foregroundStyle(.secondary).font(.footnote)
            }
            ForEach(shares, id: \.self) { share in
                NavigationLink(value: childLocation(share: share, path: "", name: share)) {
                    Label(share, systemImage: "externaldrive.connected.to.line.below")
                }
            }
        case .directory:
            if folders.isEmpty {
                Text("No subfolders here.").foregroundStyle(.secondary).font(.footnote)
            }
            ForEach(folders, id: \.self) { entry in
                NavigationLink(value: childLocation(share: shareName, path: entry.path, name: entry.name)) {
                    Label(entry.name, systemImage: "folder")
                }
            }
        }
    }

    // MARK: - Location helpers

    private var shareName: String {
        if case let .directory(share, _, _, _) = location { return share }
        return ""
    }

    private var levelTitle: String {
        switch location {
        case .shares: return "Shares"
        case .directory(_, _, _, let title): return title
        }
    }

    /// Build the child level for a tapped folder. `path` is share-relative; the
    /// saved root is `share` (at top of a share) or `share/path` (deeper).
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
