import SwiftUI
import AetherCore

/// Marker type for the `NavigationStack` route that pushes the Storage
/// detail screen. Hashable + Codable shape doesn't carry data — we
/// register `navigationDestination(for: LibraryStorageDestination.self)`
/// to build the view from the parent's environment.
struct LibraryStorageDestination: Hashable, Sendable {}

/// Storage management — total downloads, device free space, per-item
/// list with Delete actions, Clear All. Reached from `LibraryBrowseView`'s
/// "Manage downloads" disclosure row when at least one completed
/// download exists.
///
/// Read-mostly view: `DownloadObserver` provides the live snapshot, the
/// view does its own free-space probe at appear. No bespoke state
/// store; everything derives from values the rest of the app already
/// has.
struct LibraryStorageView: View {
    let downloadManager: DownloadManager?
    let downloads: DownloadObserver?

    /// Bytes available + total bytes on the device's main volume.
    /// Refreshed at appear and after every destructive action so the
    /// "free of N GB" line keeps up with reality.
    @State private var deviceCapacity: DeviceCapacity?
    @State private var isClearingAll = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                header
                breakdown
                downloadsList
                if !(downloads?.snapshot.completed.isEmpty ?? true) {
                    clearAllButton
                }
            }
            .padding(.horizontal, AetherDesign.Spacing.l)
            .padding(.top, AetherDesign.Spacing.l)
            .padding(.bottom, AetherDesign.Spacing.xxl)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AetherDesign.Gradients.background.ignoresSafeArea())
        .navigationTitle("Storage")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await refreshCapacity() }
    }

    // MARK: - Header (total + free)

    private var header: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
            Text(formatBytes(totalDownloadBytes))
                .font(AetherDesign.Typography.heroTitle)
                .foregroundStyle(AetherDesign.Palette.textPrimary)
            Text("Used by Aether downloads")
                .font(AetherDesign.Typography.metadata)
                .foregroundStyle(AetherDesign.Palette.textSecondary)
            if let capacity = deviceCapacity {
                Text("\(formatBytes(capacity.free)) free of \(formatBytes(capacity.total))")
                    .font(AetherDesign.Typography.caption)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
                    .padding(.top, AetherDesign.Spacing.xs)
            }
        }
    }

    // MARK: - Per-source breakdown

    /// Per-source split of the downloads — at MVP only Plex and Jellyfin
    /// surface, but the shape is ready for Local Library / Synology when
    /// they land. Sources with zero downloads are hidden.
    @ViewBuilder
    private var breakdown: some View {
        let groups = perSourceGroups
        if !groups.isEmpty {
            AetherSettingsSection("By source") {
                ForEach(groups, id: \.label) { group in
                    AetherSettingsRow(
                        label: group.label,
                        systemImage: group.glyph,
                        value: "\(group.count) · \(formatBytes(group.bytes))"
                    )
                }
            }
        }
    }

    // MARK: - Per-item list

    @ViewBuilder
    private var downloadsList: some View {
        let completed = downloads?.snapshot.completed ?? []
        if !completed.isEmpty {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
                Text("Downloads")
                    .font(AetherDesign.Typography.caption)
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)

                VStack(spacing: AetherDesign.Spacing.xs) {
                    ForEach(completed) { job in
                        downloadRow(job)
                    }
                }
            }
        } else {
            Text("No downloads yet. Tap Download on a movie or episode to save it here.")
                .font(AetherDesign.Typography.body)
                .foregroundStyle(AetherDesign.Palette.textSecondary)
                .frame(maxWidth: 520, alignment: .leading)
        }
    }

    @ViewBuilder
    private func downloadRow(_ job: DownloadJob) -> some View {
        let size = jobSizeBytes(job)
        HStack(spacing: AetherDesign.Spacing.m) {
            CachedAsyncImage(url: job.posterURL, aspectRatio: 2.0 / 3.0)
                .frame(width: 44, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous))

            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xxs) {
                Text(job.title)
                    .font(AetherDesign.Typography.body)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                    .lineLimit(1)
                HStack(spacing: AetherDesign.Spacing.xs) {
                    Text(sourceLabel(for: job.mediaID.source))
                        .font(AetherDesign.Typography.caption)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                    Text("·")
                        .foregroundStyle(AetherDesign.Palette.textTertiary)
                    Text(formatBytes(size))
                        .font(AetherDesign.Typography.caption)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                    Text("·")
                        .foregroundStyle(AetherDesign.Palette.textTertiary)
                    Text(job.quality.displayName)
                        .font(AetherDesign.Typography.caption)
                        .foregroundStyle(AetherDesign.Palette.textTertiary)
                }
            }
            Spacer(minLength: AetherDesign.Spacing.s)
            Button {
                Task { await delete(job) }
            } label: {
                Image(systemName: "trash")
                    .font(AetherDesign.Typography.body)
                    .foregroundStyle(AetherDesign.Palette.error)
                    .padding(AetherDesign.Spacing.s)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete \(job.title)")
        }
        .padding(.vertical, AetherDesign.Spacing.s)
        .padding(.horizontal, AetherDesign.Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                .fill(AetherDesign.Materials.card)
        )
    }

    // MARK: - Clear all

    private var clearAllButton: some View {
        AetherButton(
            isClearingAll ? "Clearing…" : "Clear All Downloads",
            systemImage: "trash",
            role: .destructive
        ) {
            Task { await clearAll() }
        }
        .disabled(isClearingAll)
    }

    // MARK: - Derived totals

    private var totalDownloadBytes: Int64 {
        downloads?.snapshot.statusByJobID.values.reduce(0) { acc, status in
            if case let .completed(_, size) = status { return acc + size }
            return acc
        } ?? 0
    }

    /// Per-source aggregation for the "By source" breakdown.
    private var perSourceGroups: [SourceGroup] {
        let completed = downloads?.snapshot.completed ?? []
        var byKey: [String: SourceGroup] = [:]
        for job in completed {
            let key = job.mediaID.source.stableKey
            let label = sourceLabel(for: job.mediaID.source)
            let glyph = sourceGlyph(for: job.mediaID.source)
            let size = jobSizeBytes(job)
            var group = byKey[key] ?? SourceGroup(label: label, glyph: glyph, count: 0, bytes: 0)
            group.count += 1
            group.bytes += size
            byKey[key] = group
        }
        return byKey.values.sorted { $0.label < $1.label }
    }

    private struct SourceGroup {
        let label: String
        let glyph: String
        var count: Int
        var bytes: Int64
    }

    private func jobSizeBytes(_ job: DownloadJob) -> Int64 {
        guard let status = downloads?.snapshot.statusByJobID[job.id],
              case let .completed(_, size) = status else { return 0 }
        return size
    }

    // MARK: - Source labels

    private func sourceLabel(for source: MediaSourceID) -> String {
        switch source {
        case .plex:     return "Plex"
        case .jellyfin: return "Jellyfin"
        case .synology: return "Synology"
        case .mock:     return "Mock"
        }
    }

    private func sourceGlyph(for source: MediaSourceID) -> String {
        switch source {
        case .plex:     return "play.circle.fill"
        case .jellyfin: return "rectangle.stack.badge.play.fill"
        case .synology: return "externaldrive.fill"
        case .mock:     return "questionmark.circle.fill"
        }
    }

    // MARK: - Capacity probe

    private struct DeviceCapacity: Sendable {
        let free: Int64
        let total: Int64
    }

    /// Read the home directory's filesystem stats — the volume Aether's
    /// downloads live on. Fails silently (capacity stays nil and the
    /// "free of N GB" line just doesn't render).
    private func refreshCapacity() async {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: url.path),
              let free = attrs[.systemFreeSize] as? NSNumber,
              let total = attrs[.systemSize] as? NSNumber else { return }
        deviceCapacity = DeviceCapacity(
            free: free.int64Value,
            total: total.int64Value
        )
    }

    // MARK: - Destructive actions

    private func delete(_ job: DownloadJob) async {
        guard let manager = downloadManager else { return }
        await manager.remove(job.id)
        await refreshCapacity()
    }

    private func clearAll() async {
        guard let manager = downloadManager, let downloads else { return }
        isClearingAll = true
        defer { isClearingAll = false }
        for job in downloads.snapshot.completed {
            await manager.remove(job.id)
        }
        await refreshCapacity()
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
