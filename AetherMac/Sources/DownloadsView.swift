import SwiftUI
import AetherCore

/// Downloads management popover — in-progress jobs and completed titles.
/// Opened from the toolbar download button in the main window.
struct DownloadsView: View {
    let session: MacSession

    private var snapshot: DownloadSnapshot { session.downloadObserver?.snapshot ?? .empty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if snapshot.inProgress.isEmpty && snapshot.completed.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !snapshot.inProgress.isEmpty {
                            sectionHeader("In Progress")
                            ForEach(snapshot.inProgress) { job in
                                inProgressRow(job)
                                Divider().padding(.leading, 56)
                            }
                        }
                        if !snapshot.completed.isEmpty {
                            sectionHeader("Downloaded")
                            ForEach(snapshot.completed) { job in
                                completedRow(job)
                                Divider().padding(.leading, 56)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 360)
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxHeight: 480)
    }

    private var totalCompletedBytes: Int64 {
        snapshot.completed.reduce(into: 0) { acc, job in
            if case .completed(_, let bytes) = snapshot.statusByJobID[job.id] {
                acc += bytes
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Downloads")
                    .font(.headline)
                Spacer()
                if !snapshot.completed.isEmpty {
                    Button("Clear All", role: .destructive) {
                        snapshot.completed.forEach { session.removeDownload($0.id) }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            if totalCompletedBytes > 0 {
                Text("\(DetailFormatting.fileSize(totalCompletedBytes)) used · ~/Movies/Aether")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No downloads yet")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Open a title and tap Download to save it for offline viewing.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }

    @ViewBuilder
    private func inProgressRow(_ job: DownloadJob) -> some View {
        let status = snapshot.statusByJobID[job.id] ?? .notDownloaded
        let live = snapshot.liveProgress(for: job.id)
        HStack(spacing: 12) {
            posterThumb(job)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.displayTitle)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                progressLabel(status: status, live: live)
                if let fraction = status.fractionCompleted {
                    ProgressView(value: fraction)
                        .tint(AetherMacTheme.accent)
                }
            }
            Spacer(minLength: 0)
            inProgressActions(job: job, status: status)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func inProgressActions(job: DownloadJob, status: DownloadStatus) -> some View {
        switch status {
        case .downloading:
            HStack(spacing: 8) {
                Button { session.pauseDownload(job.id) } label: {
                    Image(systemName: "pause.fill").font(.caption)
                }
                .buttonStyle(.borderless)
                Button(role: .destructive) { session.cancelDownload(job.id) } label: {
                    Image(systemName: "xmark").font(.caption)
                }
                .buttonStyle(.borderless)
            }
        case .paused:
            HStack(spacing: 8) {
                Button { session.resumeDownload(job.id) } label: {
                    Image(systemName: "play.fill").font(.caption)
                }
                .buttonStyle(.borderless)
                Button(role: .destructive) { session.cancelDownload(job.id) } label: {
                    Image(systemName: "xmark").font(.caption)
                }
                .buttonStyle(.borderless)
            }
        case .failed:
            Button { session.removeDownload(job.id) } label: {
                Image(systemName: "xmark").font(.caption)
            }
            .buttonStyle(.borderless)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func completedRow(_ job: DownloadJob) -> some View {
        let status = snapshot.statusByJobID[job.id] ?? .notDownloaded
        HStack(spacing: 12) {
            posterThumb(job)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.displayTitle)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                if case .completed(_, let bytes) = status {
                    Text(DetailFormatting.fileSize(bytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button(role: .destructive) { session.removeDownload(job.id) } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func posterThumb(_ job: DownloadJob) -> some View {
        CachedAsyncImage(url: job.displayPosterURL, contentMode: .fill)
            .frame(width: 36, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .background(Color.secondary.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private func progressLabel(status: DownloadStatus, live: DownloadLiveProgress?) -> some View {
        if let live, let fraction = status.fractionCompleted {
            let received = DetailFormatting.fileSize(live.receivedBytes)
            let total = DetailFormatting.fileSize(live.totalBytes)
            let speed = DetailFormatting.fileSize(Int64(live.bytesPerSecond)) + "/s"
            Text("\(received) of \(total) · \(speed)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            let _ = fraction // silence unused warning
        } else {
            Text(statusLabel(status))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func statusLabel(_ status: DownloadStatus) -> String {
        switch status {
        case .queued:              return "Queued"
        case .downloading(let f): return String(format: "%.0f%%", f * 100)
        case .paused:             return "Paused"
        case .failed(let r):      return "Failed: \(r)"
        case .completed:          return "Done"
        default:                  return ""
        }
    }
}
