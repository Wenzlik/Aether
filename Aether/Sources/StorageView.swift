import SwiftUI
import AetherCore

// tvOS has no downloads UI (see RootTabView's `dlManager` rationale), so the
// whole Storage screen — built on `List` + `listRowSeparator(.hidden)` which
// is unavailable on tvOS — compiles out for that platform.
#if !os(tvOS)

/// Storage — Aether's download manager.
///
/// Reached via **Settings → Downloads** (it used to be a top-level tab; the
/// nav refactor folded it in, since downloads are an Offline *source*, not a
/// separate area). Hosted in the Settings `NavigationStack` via `embedded:
/// true`, where it titles itself "Downloads".
///
/// Surfaces total downloaded bytes, device free space, per-source
/// breakdown, per-item list with Delete actions, and a destructive
/// Clear All. The empty state is the first thing a new user sees here
/// (no downloads yet → "Tap Download on a movie or episode to save it
/// here"), so the tab does double duty as feature discovery for users
/// who haven't tried downloads.
///
/// Built on a `List` so both in-progress and completed rows get native
/// **swipe-to-delete**; the gradient background and clear row styling
/// keep the card look the rest of the app uses.
struct StorageView: View {
    /// Plumbed in from `RootTabView` so a Storage row can push a real
    /// `DetailView` (which needs the same dependencies any other
    /// drill-in needs: a source to resolve fresh URLs, the resume
    /// store, the playback session). Pre-boot the values are nil —
    /// `mediaNavigationDestinations` guards on those, so taps no-op
    /// safely until AppSession is ready.
    let source: (any MediaSource)?
    let resumeStore: ResumeStore
    let playbackSession: PlaybackSession
    let libraryPreferences: LibraryPreferencesStore
    let downloadManager: DownloadManager?
    let downloads: DownloadObserver?
    /// Forwarded to DetailView via `mediaNavigationDestinations`.
    let playbackPreferences: PlaybackPreferencesStore?
    /// When `true`, the screen is hosted inside another `NavigationStack`
    /// (Settings → Downloads) so it renders its content bare — the host owns the
    /// stack — and titles itself "Downloads". When `false` (legacy standalone
    /// use) it wraps itself in a `NavigationStack` titled "Storage".
    var embedded: Bool = false

    /// Bytes available + total bytes on the device's main volume.
    /// Refreshed at appear and after every destructive action so the
    /// "free of N GB" line keeps up with reality.
    @State private var deviceCapacity: DeviceCapacity?
    @State private var isClearingAll = false

    var body: some View {
        if embedded {
            listContent
        } else {
            NavigationStack { listContent }
        }
    }

    /// The download manager list + its modifiers. The `mediaNavigationDestinations`
    /// register on whichever `NavigationStack` encloses this view — its own
    /// (standalone) or the Settings stack (embedded), so a downloaded-item tap
    /// pushes Detail either way.
    private var listContent: some View {
        List {
            Section { header.listRowSeparator(.hidden) }
                .listRowBackground(Color.clear)
                .listRowInsets(rowInsets)

            inProgressSection
            breakdownSection
            downloadedSection
            clearAllSection
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AetherDesign.Gradients.background.ignoresSafeArea())
        .navigationTitle(embedded ? "Downloads" : "Storage")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .task { await refreshCapacity() }
        .mediaNavigationDestinations(
            source: source,
            resumeStore: resumeStore,
            playbackSession: playbackSession,
            libraryPreferences: libraryPreferences,
            downloadManager: downloadManager,
            downloads: downloads,
            playbackPreferences: playbackPreferences
        )
    }

    /// Uniform insets that make List rows sit like the app's free-standing
    /// cards (full-bleed horizontally within the 720pt reading column).
    private var rowInsets: EdgeInsets {
        EdgeInsets(
            top: AetherDesign.Spacing.xs,
            leading: AetherDesign.Spacing.l,
            bottom: AetherDesign.Spacing.xs,
            trailing: AetherDesign.Spacing.l
        )
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
        .padding(.top, AetherDesign.Spacing.s)
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

    // MARK: - In Progress section

    /// Every job that's not yet `.completed`. Hidden when there are none.
    /// Each row swipes left to delete (cancels the task + removes partial
    /// files); the trailing button is the state's primary next step.
    @ViewBuilder
    private var inProgressSection: some View {
        let inProgress = downloads?.snapshot.inProgress ?? []
        if !inProgress.isEmpty {
            Section {
                ForEach(inProgress) { job in
                    deletable(inProgressRow(job), job: job)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(rowInsets)
                }
            } header: {
                sectionHeader("In Progress")
            }
        }
    }

    @ViewBuilder
    private func inProgressRow(_ job: DownloadJob) -> some View {
        let status = downloads?.snapshot.statusByJobID[job.id] ?? .notDownloaded
        let live = downloads?.snapshot.liveProgress(for: job.id)
        NavigationLink(value: syntheticMediaItem(for: job)) {
            HStack(spacing: AetherDesign.Spacing.m) {
                CachedAsyncImage(url: job.posterURL, aspectRatio: 2.0 / 3.0)
                    .frame(width: 44, height: 66)
                    .clipShape(RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous))

                VStack(alignment: .leading, spacing: AetherDesign.Spacing.xxs) {
                    Text(job.displayTitle)
                        .font(AetherDesign.Typography.body)
                        .foregroundStyle(AetherDesign.Palette.textPrimary)
                        .lineLimit(1)
                    Text(inProgressDetail(for: status, live: live, job: job))
                        .font(AetherDesign.Typography.caption)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                        .lineLimit(2)
                    if let fraction = progressFraction(for: status) {
                        ProgressView(value: fraction)
                            .tint(AetherDesign.Palette.accent)
                            .padding(.top, AetherDesign.Spacing.xxs)
                    }
                }
                Spacer(minLength: AetherDesign.Spacing.s)
                inProgressAction(for: status, job: job)
                #if os(tvOS)
                deleteButton(job)
                #endif
            }
            .padding(.vertical, AetherDesign.Spacing.s)
            .padding(.horizontal, AetherDesign.Spacing.m)
            .background(
                RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                    .fill(AetherDesign.Materials.card)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Progress fraction for the row's bar — downloading + paused only.
    private func progressFraction(for status: DownloadStatus) -> Double? {
        switch status {
        case let .downloading(fraction), let .paused(fraction):
            return min(max(fraction, 0), 1)
        default:
            return nil
        }
    }

    /// Status line for an in-progress row. While downloading, packs the live
    /// detail the user asked for: "Plex · 1.2 of 3.4 GB · 12 MB/s · 4 min
    /// left". Falls back to coarser text for the other states.
    private func inProgressDetail(
        for status: DownloadStatus,
        live: DownloadLiveProgress?,
        job: DownloadJob
    ) -> String {
        let prefix = sourceLabel(for: job.mediaID.source)
        switch status {
        case .queued:
            return "\(prefix) · Queued"
        case let .downloading(fraction):
            var parts: [String] = [prefix]
            if let live, live.totalBytes > 0 {
                parts.append("\(formatBytes(live.receivedBytes)) of \(formatBytes(live.totalBytes))")
            } else {
                parts.append("Downloading \(Int((fraction * 100).rounded()))%")
            }
            if let live, live.bytesPerSecond > 0 {
                parts.append("\(formatBytes(Int64(live.bytesPerSecond)))/s")
            }
            if let live, let eta = live.estimatedSecondsRemaining {
                parts.append(formatETA(eta))
            }
            return parts.joined(separator: " · ")
        case let .paused(fraction):
            return "\(prefix) · Paused at \(Int((fraction * 100).rounded()))%"
        case let .failed(reason):
            return "\(prefix) · Failed · \(reason)"
        case .expired:
            return "\(prefix) · Expired"
        case .completed, .notDownloaded:
            return prefix
        }
    }

    /// Primary action for an in-progress row, picked by status. Delete is
    /// always available via swipe, so this stays a single, obvious next step.
    @ViewBuilder
    private func inProgressAction(for status: DownloadStatus, job: DownloadJob) -> some View {
        switch status {
        case .downloading:
            rowActionButton("Pause") { await pauseDownload(job) }
        case .paused:
            rowActionButton("Resume") { await resumeDownload(job) }
        case .failed, .expired:
            rowActionButton("Retry") { await retryDownload(job) }
        case .queued, .completed, .notDownloaded:
            EmptyView()
        }
    }

    private func rowActionButton(_ title: String, _ action: @escaping () async -> Void) -> some View {
        Button(title) { Task { await action() } }
            .buttonStyle(.plain)
            .font(AetherDesign.Typography.metadata)
            .foregroundStyle(AetherDesign.Palette.accent)
    }

    /// Apply native swipe-to-delete where the platform supports it. tvOS has no
    /// swipe gesture, so rows there carry a visible trash button instead (added
    /// in the row body under `#if os(tvOS)`).
    @ViewBuilder
    private func deletable(_ content: some View, job: DownloadJob) -> some View {
        #if os(tvOS)
        content
        #else
        content.swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                Task { await delete(job) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        #endif
    }

    #if os(tvOS)
    /// tvOS delete affordance — a focusable trash button, since there's no
    /// swipe gesture on the platform.
    private func deleteButton(_ job: DownloadJob) -> some View {
        Button { Task { await delete(job) } } label: {
            Image(systemName: "trash")
                .font(AetherDesign.Typography.body)
                .foregroundStyle(AetherDesign.Palette.error)
                .padding(AetherDesign.Spacing.s)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Delete \(job.title)")
    }
    #endif

    // MARK: - Per-source breakdown

    /// Per-source split of the downloads — at MVP only Plex and Jellyfin
    /// surface, but the shape is ready for Local Library / Synology when
    /// they land. Sources with zero downloads are hidden.
    @ViewBuilder
    private var breakdownSection: some View {
        let groups = perSourceGroups
        if !groups.isEmpty {
            Section {
                ForEach(groups, id: \.label) { group in
                    HStack {
                        Label(group.label, systemImage: group.glyph)
                            .font(AetherDesign.Typography.body)
                            .foregroundStyle(AetherDesign.Palette.textPrimary)
                        Spacer()
                        Text("\(group.count) · \(formatBytes(group.bytes))")
                            .font(AetherDesign.Typography.caption)
                            .foregroundStyle(AetherDesign.Palette.textSecondary)
                    }
                    .padding(.vertical, AetherDesign.Spacing.s)
                    .padding(.horizontal, AetherDesign.Spacing.m)
                    .background(
                        RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                            .fill(AetherDesign.Materials.card)
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(rowInsets)
                }
            } header: {
                sectionHeader("By source")
            }
        }
    }

    // MARK: - Downloaded section

    @ViewBuilder
    private var downloadedSection: some View {
        let completed = downloads?.snapshot.completed ?? []
        let inProgress = downloads?.snapshot.inProgress ?? []
        if !completed.isEmpty {
            Section {
                ForEach(completed) { job in
                    deletable(downloadRow(job), job: job)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(rowInsets)
                }
            } header: {
                sectionHeader("Downloaded")
            }
        } else if inProgress.isEmpty {
            // Only show the "No downloads yet" prompt when there's truly
            // nothing — completed *or* in-flight.
            Section {
                Text("No downloads yet. Tap Download on a movie or episode to save it here.")
                    .font(AetherDesign.Typography.body)
                    .foregroundStyle(AetherDesign.Palette.textSecondary)
                    .frame(maxWidth: 520, alignment: .leading)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(rowInsets)
            }
        }
    }

    @ViewBuilder
    private func downloadRow(_ job: DownloadJob) -> some View {
        let size = jobSizeBytes(job)
        NavigationLink(value: syntheticMediaItem(for: job)) {
            HStack(spacing: AetherDesign.Spacing.m) {
                CachedAsyncImage(url: job.posterURL, aspectRatio: 2.0 / 3.0)
                    .frame(width: 44, height: 66)
                    .clipShape(RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous))

                VStack(alignment: .leading, spacing: AetherDesign.Spacing.xxs) {
                    Text(job.displayTitle)
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
                #if os(tvOS)
                deleteButton(job)
                #endif
            }
            .padding(.vertical, AetherDesign.Spacing.s)
            .padding(.horizontal, AetherDesign.Spacing.m)
            .background(
                RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                    .fill(AetherDesign.Materials.card)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Section header styled like the app's other uppercase rail labels,
    /// minus List's default inset/casing.
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(AetherDesign.Typography.caption)
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(AetherDesign.Palette.textTertiary)
            .listRowInsets(rowInsets)
    }

    /// Build a minimal `MediaItem` from a download job. `mediaNavigationDestinations`
    /// then routes it to `DetailView`, which uses the live source to
    /// hydrate full metadata + audio/sub/quality tracks.
    private func syntheticMediaItem(for job: DownloadJob) -> MediaItem {
        MediaItem(
            id: job.mediaID,
            title: job.title,
            kind: job.kind,
            posterURL: job.posterURL,
            seriesTitle: job.seriesTitle,
            seasonNumber: job.seasonNumber,
            episodeNumber: job.episodeNumber
        )
    }

    // MARK: - Clear all

    @ViewBuilder
    private var clearAllSection: some View {
        if !(downloads?.snapshot.completed.isEmpty ?? true) {
            Section {
                AetherButton(
                    isClearingAll ? "Clearing…" : "Clear All Downloads",
                    systemImage: "trash",
                    role: .destructive
                ) {
                    Task { await clearAll() }
                }
                .disabled(isClearingAll)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(rowInsets)
            }
        }
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

    /// Restart a failed/expired download. The manager resumes from persisted
    /// resume data when it has it, otherwise re-downloads from the job's stored
    /// URL — so Retry works straight from Storage without a live source.
    private func retryDownload(_ job: DownloadJob) async {
        await downloadManager?.resume(job.id)
        await refreshCapacity()
    }

    // MARK: - Formatting

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// "4 min left" / "about 1 hr left" / "12 sec left" — rounded coarsely so
    /// it doesn't jitter every tick.
    private func formatETA(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 {
            return "\(max(total, 1)) sec left"
        }
        if total < 3600 {
            let minutes = Int((Double(total) / 60).rounded())
            return "\(minutes) min left"
        }
        let hours = Double(total) / 3600
        if hours < 1.5 { return "about 1 hr left" }
        return "about \(Int(hours.rounded())) hr left"
    }
}

#endif // !os(tvOS)
