import SwiftUI
import AetherCore

/// Storage — Aether's download manager tab.
///
/// A **top-level tab** next to Home / Library / Settings in
/// `RootTabView`. Replaces what used to be the Search tab; search moved
/// into the `.searchable` modifier on Home + Library (the iOS-native
/// "search lives in the tab that owns the content" pattern that Music /
/// Photos / TV+ use).
///
/// Surfaces total downloaded bytes, device free space, per-source
/// breakdown, per-item list with Delete actions, and a destructive
/// Clear All. The empty state is the first thing a new user sees here
/// (no downloads yet → "Tap Download on a movie or episode to save it
/// here"), so the tab does double duty as feature discovery for users
/// who haven't tried downloads.
///
/// Read-mostly view: `DownloadObserver` provides the live snapshot, the
/// view does its own free-space probe at appear. No bespoke state
/// store; everything derives from values the rest of the app already
/// has.
struct StorageView: View {
    let downloadManager: DownloadManager?
    let downloads: DownloadObserver?

    /// Bytes available + total bytes on the device's main volume.
    /// Refreshed at appear and after every destructive action so the
    /// "free of N GB" line keeps up with reality.
    @State private var deviceCapacity: DeviceCapacity?
    @State private var isClearingAll = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                    header
                    inProgressList
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
            .navigationBarTitleDisplayMode(.large)
            #endif
            .task { await refreshCapacity() }
        }
    }

    // MARK: - Header (total + free + in-progress count)

    private var header: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
            Text(formatBytes(totalDownloadBytes))
                .font(AetherDesign.Typography.heroTitle)
                .foregroundStyle(AetherDesign.Palette.textPrimary)
            Text(headerSubtitle)
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

    /// "Used by Aether downloads" — or with an "N in progress" suffix when
    /// there are active jobs so the user knows the number behind the
    /// In Progress section without scrolling.
    private var headerSubtitle: String {
        let activeCount = downloads?.snapshot.inProgress.count ?? 0
        if activeCount == 0 {
            return "Used by Aether downloads"
        }
        let unit = activeCount == 1 ? "download" : "downloads"
        return "Used by Aether downloads · \(activeCount) \(unit) in progress"
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
        let inProgress = downloads?.snapshot.inProgress ?? []
        if !completed.isEmpty {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
                Text("Downloaded")
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
        } else if inProgress.isEmpty {
            // Only show the "No downloads yet" prompt when there's
            // truly nothing — completed *or* in-flight. An active
            // download with no completed siblings would otherwise read
            // as both "In Progress" *and* "no downloads yet", which
            // contradicts itself.
            Text("No downloads yet. Tap Download on a movie or episode to save it here.")
                .font(AetherDesign.Typography.body)
                .foregroundStyle(AetherDesign.Palette.textSecondary)
                .frame(maxWidth: 520, alignment: .leading)
        }
    }

    /// "In Progress" section — every job that's not yet `.completed`.
    /// Hidden when there are no active jobs; otherwise sits between the
    /// header and the per-source breakdown so the user sees their
    /// running download right at the top of the tab.
    @ViewBuilder
    private var inProgressList: some View {
        let inProgress = downloads?.snapshot.inProgress ?? []
        if !inProgress.isEmpty {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
                Text("In Progress")
                    .font(AetherDesign.Typography.caption)
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)

                VStack(spacing: AetherDesign.Spacing.xs) {
                    ForEach(inProgress) { job in
                        inProgressRow(job)
                    }
                }
            }
        }
    }

    /// Active-download row: poster + title + status text + a trailing
    /// action button whose label depends on the state (Pause / Resume /
    /// Retry / Cancel). Source label sits under the title so the user
    /// knows which server this is downloading from when multiple are
    /// connected.
    @ViewBuilder
    private func inProgressRow(_ job: DownloadJob) -> some View {
        let status = downloads?.snapshot.statusByJobID[job.id] ?? .notDownloaded
        HStack(spacing: AetherDesign.Spacing.m) {
            CachedAsyncImage(url: job.posterURL, aspectRatio: 2.0 / 3.0)
                .frame(width: 44, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous))

            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xxs) {
                Text(job.title)
                    .font(AetherDesign.Typography.body)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                    .lineLimit(1)
                Text(inProgressDetail(for: status, job: job))
                    .font(AetherDesign.Typography.caption)
                    .foregroundStyle(AetherDesign.Palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: AetherDesign.Spacing.s)
            inProgressAction(for: status, job: job)
        }
        .padding(.vertical, AetherDesign.Spacing.s)
        .padding(.horizontal, AetherDesign.Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                .fill(AetherDesign.Materials.card)
        )
    }

    /// One-line status text for the in-progress row. Combines source
    /// label + state-specific detail so the second line is always
    /// informative: "Plex · Downloading 47%" / "Plex · Paused at 47%" /
    /// "Plex · Failed · HTTP 401".
    private func inProgressDetail(for status: DownloadStatus, job: DownloadJob) -> String {
        let prefix = sourceLabel(for: job.mediaID.source)
        let state: String
        switch status {
        case .queued:
            state = "Queued"
        case let .downloading(fraction):
            state = fraction > 0
                ? "Downloading \(Int((fraction * 100).rounded()))%"
                : "Downloading"
        case let .paused(fraction):
            state = "Paused at \(Int((fraction * 100).rounded()))%"
        case let .failed(reason):
            state = "Failed · \(reason)"
        case .expired:
            state = "Expired"
        case .completed, .notDownloaded:
            state = ""
        }
        return state.isEmpty ? prefix : "\(prefix) · \(state)"
    }

    /// Primary action for an in-progress row, picked by status:
    /// Downloading → Pause, Paused → Resume, Failed/Expired → Retry,
    /// Queued → Cancel. Each state has one obvious next step; we never
    /// show two buttons (would compete for attention) — Delete is on
    /// the completed row instead.
    @ViewBuilder
    private func inProgressAction(for status: DownloadStatus, job: DownloadJob) -> some View {
        switch status {
        case .queued:
            Button("Cancel") { Task { await cancelDownload(job) } }
                .buttonStyle(.plain)
                .font(AetherDesign.Typography.metadata)
                .foregroundStyle(AetherDesign.Palette.accent)
        case .downloading:
            Button("Pause") { Task { await pauseDownload(job) } }
                .buttonStyle(.plain)
                .font(AetherDesign.Typography.metadata)
                .foregroundStyle(AetherDesign.Palette.accent)
        case .paused:
            Button("Resume") { Task { await resumeDownload(job) } }
                .buttonStyle(.plain)
                .font(AetherDesign.Typography.metadata)
                .foregroundStyle(AetherDesign.Palette.accent)
        case .failed, .expired:
            Button("Retry") { Task { await retryDownload(job) } }
                .buttonStyle(.plain)
                .font(AetherDesign.Typography.metadata)
                .foregroundStyle(AetherDesign.Palette.accent)
        case .completed, .notDownloaded:
            EmptyView()
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

    // MARK: - In-progress actions

    private func pauseDownload(_ job: DownloadJob) async {
        await downloadManager?.pause(job.id)
    }

    private func resumeDownload(_ job: DownloadJob) async {
        await downloadManager?.resume(job.id)
    }

    private func cancelDownload(_ job: DownloadJob) async {
        await downloadManager?.cancel(job.id)
    }

    /// Drop the failed/expired record and re-enqueue with the same
    /// quality. URLSession's resume-data for the failed task is gone by
    /// then; a fresh start is the only path. The source lookup goes
    /// through `mediaID.source` — we don't have a live MediaSource
    /// reference here, but the user can also Retry from Detail (which
    /// does have one). For Storage tab we drop the failed record
    /// silently and let the user re-trigger from Detail; that's the
    /// simplest path that doesn't require plumbing a source resolver
    /// into Storage just for retries.
    private func retryDownload(_ job: DownloadJob) async {
        await downloadManager?.remove(job.id)
        await refreshCapacity()
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
