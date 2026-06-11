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
                    #if os(tvOS)
                    diagnosticsColumns(snapshot)
                    #else
                    content(snapshot)
                    #endif
                } else {
                    ProgressView()
                        .tint(AetherDesign.Palette.accent)
                        .frame(maxWidth: .infinity, minHeight: 160)
                }
            }
            .padding(AetherDesign.Spacing.l)
            #if os(tvOS)
            // Wide two-column layout on the 10-foot UI; each section (below) is a
            // focus stop so the Siri Remote can move through and scroll them (#266).
            .frame(maxWidth: 1500, alignment: .leading)
            .frame(maxWidth: .infinity)
            #else
            .frame(maxWidth: AetherSheetLayout.maxContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            #endif
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

    /// Single column (touch / pointer) — the sections stacked in the outer VStack.
    @ViewBuilder
    private func content(_ snapshot: DiagnosticsSnapshot) -> some View {
        appSection(snapshot)
        sourcesSection(snapshot)
        librarySection(snapshot)
        downloadsSection(snapshot)
        cacheSection(snapshot)
        playbackSection(snapshot)
    }

    #if os(tvOS)
    /// Two columns on the 10-foot UI — uses the wide screen, and each section is a
    /// focus stop so the Siri Remote can move through (and scroll) them (#266).
    @ViewBuilder
    private func diagnosticsColumns(_ snapshot: DiagnosticsSnapshot) -> some View {
        HStack(alignment: .top, spacing: AetherDesign.Spacing.xl) {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                appSection(snapshot)
                sourcesSection(snapshot)
                librarySection(snapshot)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                downloadsSection(snapshot)
                cacheSection(snapshot)
                playbackSection(snapshot)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    #endif

    // MARK: - Sections (each a tvOS focus stop so the remote can scroll the list)

    @ViewBuilder private func appSection(_ s: DiagnosticsSnapshot) -> some View {
        AetherSettingsSection("App") {
            AetherSettingsRow(label: "Version", value: s.appVersion)
            AetherSettingsRow(label: "Build", value: s.buildNumber)
            if let commit = s.commit {
                AetherSettingsRow(label: "Commit", value: commit)
            }
            AetherSettingsRow(label: "Platform", value: s.platform)
            AetherSettingsRow(label: "Device", value: s.deviceModel)
            AetherSettingsRow(label: "OS", value: s.osVersion)
        }
        .tvOSScrollFocusable()
    }

    @ViewBuilder private func sourcesSection(_ s: DiagnosticsSnapshot) -> some View {
        AetherSettingsSection("Sources") {
            if s.sources.isEmpty {
                AetherSettingsRow(label: "Status", value: "None connected")
            } else {
                ForEach(s.sources) { source in
                    AetherSettingsRow(label: source.name, status: .positive(source.status))
                }
            }
        }
        .tvOSScrollFocusable()
    }

    @ViewBuilder private func librarySection(_ s: DiagnosticsSnapshot) -> some View {
        AetherSettingsSection("Library") {
            AetherSettingsRow(label: "Movies", value: "\(s.movieCount)")
            AetherSettingsRow(label: "TV Shows", value: "\(s.showCount)")
        }
        .tvOSScrollFocusable()
    }

    @ViewBuilder private func downloadsSection(_ s: DiagnosticsSnapshot) -> some View {
        AetherSettingsSection("Downloads") {
            AetherSettingsRow(label: "Items", value: "\(s.downloadCount)")
            AetherSettingsRow(label: "Storage", value: s.downloadBytesText)
        }
        .tvOSScrollFocusable()
    }

    @ViewBuilder private func cacheSection(_ s: DiagnosticsSnapshot) -> some View {
        AetherSettingsSection("Cache") {
            AetherSettingsRow(label: "Images", value: s.imageCacheText)
        }
        .tvOSScrollFocusable()
    }

    @ViewBuilder private func playbackSection(_ s: DiagnosticsSnapshot) -> some View {
        AetherSettingsSection("Playback") {
            AetherSettingsRow(label: "Audio", value: s.audioPreference)
            AetherSettingsRow(label: "Subtitles", value: s.subtitlePreference)
        }
        .tvOSScrollFocusable()
    }
}
