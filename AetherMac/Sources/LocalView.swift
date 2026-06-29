import SwiftUI
import AetherCore
import AVFoundation
import UniformTypeIdentifiers

/// The "Local" sidebar section: a play queue (Up Next) plus recently-opened
/// files, for ad-hoc local media — separate from the server library. Drag video
/// files (or folders) onto the view to queue them; click a row to play (resuming
/// where you left off). Finishing a file auto-advances to the next in the queue.
struct LocalView: View {
    @Bindable var session: MacSession
    var recents: RecentsStore
    @State private var isTargeted = false
    @State private var selection: URL?
    /// Resume position (seconds) per recent URL, loaded from the resume store.
    @State private var resume: [URL: Double] = [:]
    /// Lazily-generated poster frames, keyed by URL.
    @State private var thumbs: [URL: NSImage] = [:]

    var body: some View {
        List(selection: $selection) {
            if !session.playQueue.isEmpty {
                Section {
                    ForEach(session.playQueue, id: \.self) { url in
                        row(url, queued: true).tag(url)
                    }
                    .onMove { session.moveQueue(fromOffsets: $0, toOffset: $1) }
                } header: {
                    sectionHeader("Up Next", clear: { session.clearQueue() })
                }
            }

            Section {
                if recents.urls.isEmpty {
                    Text("Open a video file to see it here — drag files or folders in to queue them.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(recents.urls, id: \.self) { url in
                        row(url, queued: false)
                            .tag(url)
                            .swipeActions {
                                Button(role: .destructive) { recents.remove(url) } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                    }
                }
            } header: {
                sectionHeader("Recently Opened", clear: recents.urls.isEmpty ? nil : { recents.clear() })
            }
        }
        .listStyle(.inset)
        .navigationTitle("Local")
        .toolbar {
            Button { openPanel() } label: { Label("Open…", systemImage: "plus") }
        }
        .onDeleteCommand { deleteSelection() }
        .dropDestination(for: URL.self) { urls, _ in
            let videos = expandVideos(urls)
            session.enqueue(videos)
            return !videos.isEmpty
        } isTargeted: { isTargeted = $0 }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(AetherMacTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .cinematicBackground()
        .task(id: recents.urls + session.playQueue) { await refresh() }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(_ url: URL, queued: Bool) -> some View {
        HStack(spacing: 10) {
            thumbnail(url)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.deletingPathExtension().lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let seconds = resume[url], seconds > 1 {
                    Label("Resume \(Self.timecode(seconds))", systemImage: "play.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
            }
            Spacer(minLength: 8)
            if queued {
                Button { session.removeFromQueue(url) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).help("Remove from Up Next")
            } else {
                Button { session.enqueue([url]) } label: { Image(systemName: "text.append") }
                    .buttonStyle(.borderless).help("Add to Up Next")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { play(url, queued: queued) }
        .contextMenu {
            Button(queued ? "Play" : "Play") { play(url, queued: queued) }
            if !queued { Button("Add to Up Next") { session.enqueue([url]) } }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            Button("Remove", role: .destructive) {
                queued ? session.removeFromQueue(url) : recents.remove(url)
            }
        }
    }

    @ViewBuilder
    private func thumbnail(_ url: URL) -> some View {
        Group {
            if let image = thumbs[url] {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "film").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 64, height: 36)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func sectionHeader(_ title: String, clear: (() -> Void)?) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let clear { Button("Clear", action: clear).buttonStyle(.link) }
        }
    }

    // MARK: - Actions

    private func play(_ url: URL, queued: Bool) {
        _ = url.startAccessingSecurityScopedResource()
        recents.add(url)
        if queued { session.playFromQueue(url) } else { session.playLocal(url) }
    }

    private func deleteSelection() {
        guard let url = selection else { return }
        if session.playQueue.contains(url) { session.removeFromQueue(url) }
        else { recents.remove(url) }
        selection = nil
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = HomeView.videoTypes
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        // Play the first; queue the rest.
        play(panel.urls[0], queued: false)
        if panel.urls.count > 1 { session.enqueue(Array(panel.urls.dropFirst())) }
    }

    /// Expand any dropped folders into the video files they contain (one level
    /// deep is enough for typical "a movie's folder"); pass files through.
    private func expandVideos(_ urls: [URL]) -> [URL] {
        let exts = Set(["mp4", "m4v", "mov", "mkv", "avi", "ts", "m2ts", "webm"])
        var result: [URL] = []
        for url in urls where url.isFileURL {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                let contents = (try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil)) ?? []
                result += contents.filter { exts.contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
            } else if exts.contains(url.pathExtension.lowercased()) {
                result.append(url)
            }
        }
        return result
    }

    // MARK: - Async metadata

    /// Load resume positions + poster thumbnails for the visible files.
    private func refresh() async {
        let urls = Array(Set(recents.urls + session.playQueue))
        for url in urls {
            if resume[url] == nil {
                let item = MacSession.localItem(for: url)
                if let seconds = await session.savedResumeSeconds(for: item) {
                    resume[url] = seconds
                }
            }
            if thumbs[url] == nil, let image = await Self.thumbnail(for: url) {
                thumbs[url] = image
            }
        }
    }

    private static func thumbnail(for url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 90)
        let time = CMTime(seconds: 12, preferredTimescale: 600)
        guard let cg = try? await generator.image(at: time).image else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }

    private static func timecode(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
