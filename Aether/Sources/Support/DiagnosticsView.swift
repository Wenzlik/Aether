import SwiftUI
import AetherCore

/// A readable, user-facing diagnostics screen — sources, library, downloads,
/// cache, and build info. Not a developer console: every value is a plain
/// count, size, or status. Token-free.
struct DiagnosticsView: View {
    let gather: () async -> DiagnosticsSnapshot
    let onClose: () -> Void

    @State private var snapshot: DiagnosticsSnapshot?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
                    Text("Diagnostics")
                        .font(AetherDesign.Typography.heroTitle)
                        .foregroundStyle(AetherDesign.Palette.textPrimary)
                    Text("A snapshot of Aether on this device. No account details are included.")
                        .font(AetherDesign.Typography.metadata)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                }

                if let snapshot {
                    content(snapshot)
                } else {
                    ProgressView()
                        .tint(AetherDesign.Palette.accent)
                        .frame(maxWidth: .infinity, minHeight: 160)
                }
            }
            .padding(AetherDesign.Spacing.l)
            .frame(maxWidth: AetherSheetLayout.maxContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .tvOSScrollFocusable()
        }
        .aetherScreenBackground()
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
                    .padding(AetherDesign.Spacing.m)
            }
            .buttonStyle(.plain)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task {
            if snapshot == nil { snapshot = await gather() }
        }
    }

    @ViewBuilder
    private func content(_ snapshot: DiagnosticsSnapshot) -> some View {
        AetherSettingsSection("App") {
            AetherSettingsRow(label: "Version", value: snapshot.appVersion)
            AetherSettingsRow(label: "Build", value: snapshot.buildNumber)
            if let commit = snapshot.commit {
                AetherSettingsRow(label: "Commit", value: commit)
            }
            AetherSettingsRow(label: "Platform", value: snapshot.platform)
            AetherSettingsRow(label: "Device", value: snapshot.deviceModel)
            AetherSettingsRow(label: "OS", value: snapshot.osVersion)
        }

        AetherSettingsSection("Sources") {
            if snapshot.sources.isEmpty {
                AetherSettingsRow(label: "Status", value: "None connected")
            } else {
                ForEach(snapshot.sources) { source in
                    AetherSettingsRow(label: source.name, status: .positive(source.status))
                }
            }
        }

        AetherSettingsSection("Library") {
            AetherSettingsRow(label: "Movies", value: "\(snapshot.movieCount)")
            AetherSettingsRow(label: "TV Shows", value: "\(snapshot.showCount)")
        }

        AetherSettingsSection("Downloads") {
            AetherSettingsRow(label: "Items", value: "\(snapshot.downloadCount)")
            AetherSettingsRow(label: "Storage", value: snapshot.downloadBytesText)
        }

        AetherSettingsSection("Cache") {
            AetherSettingsRow(label: "Images", value: snapshot.imageCacheText)
        }

        AetherSettingsSection("Playback") {
            AetherSettingsRow(label: "Audio", value: snapshot.audioPreference)
            AetherSettingsRow(label: "Subtitles", value: snapshot.subtitlePreference)
        }
    }
}
