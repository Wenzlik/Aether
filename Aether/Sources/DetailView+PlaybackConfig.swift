import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import AetherCore

// #241 inc 6 — playback config: compact Audio/Subtitles/Quality selectors, the
// selector sheets, media-info rows, and the Technical Details cluster. Split out
// of DetailView.swift (pure file split, no behavior change).
extension DetailView {

    // MARK: - Playback options (compact selectors + media info)

    /// Compact Audio / Subtitles / Quality rows. Each row shows the current
    /// selection in muted text and a chevron; tap opens a bottom sheet.
    var playbackSection: some View {
        AetherSettingsSection("Playback") {
            if !current.audioTracks.isEmpty {
                AetherDisclosureRow(
                    label: "Audio",
                    value: current.selectedAudioTrack?.displayTitle,
                    systemImage: "waveform"
                ) {
                    presentedSelector = .audio
                }
            }
            if !current.subtitleTracks.isEmpty {
                AetherDisclosureRow(
                    label: "Subtitles",
                    value: current.selectedSubtitleTrack?.displayTitle ?? "Off",
                    systemImage: "captions.bubble"
                ) {
                    presentedSelector = .subtitles
                }
            }
            AetherDisclosureRow(
                label: "Quality",
                value: qualityRowValue,
                systemImage: "film.stack"
            ) {
                presentedSelector = .quality
            }
        }
    }

    /// "Original · Direct Play" / "Convert Automatically" / "8 Mbps 1080p"
    /// — the chosen quality plus a hint at the projected playback mode for
    /// Original (Direct Play if container is AVPlayer-friendly, else
    /// Direct Stream). Other qualities just show their label.
    private var qualityRowValue: String {
        switch current.selectedQuality {
        case .original:
            switch projectedPlaybackMode {
            case .directPlay:   return "Original · Direct Play"
            case .directStream: return "Original · Direct Stream"
            case .transcode:    return "Original"
            }
        default:
            return current.selectedQuality.displayName
        }
    }

    /// The bottom sheet behind the disclosure rows. Half-height on iOS,
    /// full modal on tvOS / visionOS. Takes the `selector` as a
    /// parameter (passed by `.sheet(item:)` at presentation time) so it
    /// always renders the right content — see the comment at the
    /// `.sheet` call site for why reading `presentedSelector` directly
    /// here was the source of the "empty sheet on first open" bug.
    @ViewBuilder
    func playbackSelectorSheet(for selector: PlaybackSelector) -> some View {
        switch selector {
        case .audio:
            playbackSelectorContent(title: "Audio") {
                audioSelectorList
            }
        case .subtitles:
            playbackSelectorContent(title: "Subtitles") {
                subtitleSelectorList
            }
        case .quality:
            playbackSelectorContent(title: "Quality") {
                qualitySelectorList
            }
        case .downloadQuality:
            playbackSelectorContent(title: "Download Quality") {
                downloadQualitySelectorList
            }
        case .technicalDetails:
            ScrollView {
                VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                    Text("Technical Details")
                        .font(AetherDesign.Typography.sectionTitle)
                        .foregroundStyle(AetherDesign.Palette.textPrimary)
                    mediaSection
                }
                .padding(AetherDesign.Spacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .aetherScreenBackground()
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        case .smbEditMetadata:
            SMBMetadataEditSheet(
                itemID: activeItem.id,
                currentTitle: current.title,
                currentYear: current.year,
                currentPath: current.streamURL.map { url in
                    let host = url.host ?? ""
                    let decoded = url.path.removingPercentEncoding ?? url.path
                    return host.isEmpty ? decoded : "\(host)\(decoded)"
                },
                searchAsShow: activeItem.kind == .show
            ) {
                presentedSelector = nil
                localEditToken = UUID()   // re-hydrate Detail with the corrected match
            }
        #if !os(tvOS)
        case .editMetadata:
            LocalMetadataEditSheet(itemID: activeItem.id.rawValue) {
                presentedSelector = nil
                localEditToken = UUID()   // force a re-hydrate on dismiss
            }
        #endif
        }
    }

    /// The sheet body: a calm header + the option list, on the same dark
    /// background the rest of the app uses (the system sheet chrome handles
    /// the "card on top of detail" affordance).
    @ViewBuilder
    private func playbackSelectorContent<Content: View>(
        title: String,
        @ViewBuilder list: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                Text(title)
                    .font(AetherDesign.Typography.sectionTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                    .padding(.horizontal, AetherDesign.Spacing.l)
                    .padding(.top, AetherDesign.Spacing.l)

                VStack(spacing: 0) {
                    list()
                }
                .background(
                    RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                        .fill(AetherDesign.Materials.card)
                )
                .padding(.horizontal, AetherDesign.Spacing.l)
                .padding(.bottom, AetherDesign.Spacing.l)
            }
        }
        .aetherScreenBackground()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var audioSelectorList: some View {
        ForEach(current.audioTracks) { track in
            AetherSelectionRow(
                title: track.displayTitle,
                isSelected: track.id == current.selectedAudioTrackID
            ) {
                configuredItem = current.selectingAudioTrack(track)
                presentedSelector = nil
            }
        }
    }

    private var subtitleSelectorList: some View {
        Group {
            AetherSelectionRow(
                title: "Off",
                isSelected: current.selectedSubtitleTrackID == nil
            ) {
                configuredItem = current.selectingSubtitleTrack(nil)
                presentedSelector = nil
            }
            ForEach(current.subtitleTracks) { track in
                AetherSelectionRow(
                    title: track.displayTitle,
                    isSelected: track.id == current.selectedSubtitleTrackID
                ) {
                    configuredItem = current.selectingSubtitleTrack(track)
                    presentedSelector = nil
                }
            }
        }
    }

    private var qualitySelectorList: some View {
        ForEach(PlaybackQuality.allCases, id: \.self) { quality in
            AetherSelectionRow(
                title: quality.displayName,
                isSelected: quality == current.selectedQuality
            ) {
                configuredItem = current.selectingQuality(quality)
                presentedSelector = nil
            }
        }
    }

    /// Quality picker for the **Download** path. Same options as
    /// `qualitySelectorList`, different action: pick → close sheet →
    /// enqueue download with that quality. No selection state to
    /// "remember" — the user picks once per download, and the choice is
    /// recorded on the `DownloadJob`.
    private var downloadQualitySelectorList: some View {
        // On visionOS, hide "Original" for containers AVFoundation can't demux
        // (mkv, …): the only remaining choices all transcode to an mp4, which
        // the Cinema path (system `AVPlayer` docked into the immersive space)
        // can play offline. An Original mkv would be unplayable in the theater
        // offline. See `forcesTranscodeDownload`.
        let qualities = PlaybackQuality.allCases.filter {
            !(forcesTranscodeDownload && $0 == .original)
        }
        return Group {
            ForEach(qualities, id: \.self) { quality in
                AetherSelectionRow(
                    title: quality.displayName,
                    isSelected: false
                ) {
                    presentedSelector = nil
                    Task { await viewModel.startDownload(quality: quality) }
                }
            }
            if forcesTranscodeDownload {
                Text("“Original” isn’t offered here — this title’s format can’t play offline in Cinema on Vision Pro. Pick a quality to download a compatible copy.")
                    .font(AetherDesign.Typography.caption)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
                    .padding(.horizontal, AetherDesign.Spacing.l)
                    .padding(.vertical, AetherDesign.Spacing.s)
            }
        }
    }

    /// visionOS-only: the item's *original* container is one AVFoundation can't
    /// demux (mkv, …), so an Original download would be unplayable offline in
    /// Cinema (which docks the system `AVPlayer`). The download UI then offers
    /// transcode-only. Other platforms keep Original — their windowed VLCKit
    /// engine plays the local file fine. `nil` mediaInfo ⇒ don't restrict.
    private var forcesTranscodeDownload: Bool {
        #if os(visionOS)
        return VideoEngineResolver.standard.engine(forContainer: current.mediaInfo?.container) == .vlc
        #else
        return false
        #endif
    }

    /// Source media info + projected playback mode. The codecs / bitrate /
    /// resolution come from Plex metadata as the file is on disk; the
    /// "Playback" line is a best-effort guess based on container + quality.
    /// The server's actual decision is taken when Play is pressed.
    /// The Technical Details rows, shared by the always-expanded sheet
    /// (`mediaSection`) and the collapsible on-page section.
    @ViewBuilder
    private func mediaInfoRows(_ info: MediaInfo?) -> some View {
        if let video = DetailFormatting.videoLine(info) {
            AetherSettingsRow(label: "Video", value: video)
        }
        if let audio = DetailFormatting.audioLine(info) {
            AetherSettingsRow(label: "Audio", value: audio)
        }
        if let subtitles = subtitleSummary {
            AetherSettingsRow(label: "Subtitles", value: subtitles)
        }
        if let hdrBadge = DetailFormatting.hdrBadge(info) {
            AetherSettingsRow(label: "HDR", value: hdrBadge)
        }
        if let bitrate = info?.bitrateKbps, bitrate > 0 {
            AetherSettingsRow(label: "Bitrate", value: DetailFormatting.bitrate(bitrate))
        }
        if let size = info?.fileSizeBytes, size > 0 {
            AetherSettingsRow(label: "File Size", value: DetailFormatting.fileSize(size))
        }
        AetherSettingsRow(label: "Playback", status: playbackModeStatus)
        if let source {
            AetherSettingsRow(label: "Source", value: source.displayName)
        }
    }

    /// Always-expanded section — used inside the Technical Details *sheet*
    /// (reached from the compact icon row).
    @ViewBuilder
    private var mediaSection: some View {
        AetherSettingsSection("Technical Details") {
            mediaInfoRows(current.mediaInfo)
        }
    }

    /// On-page **collapsible** Technical Details — defaults collapsed so the
    /// info is available without padding out the page (§6). The header toggles;
    /// the rows live in the same frosted card `AetherSettingsSection` uses.
    @ViewBuilder
    var technicalDetailsSection: some View {
        // tvOS: always-expanded (no toggle). The collapsible disclosure animated
        // a layout/height change inside the focusable ScrollView, which could
        // corrupt focus geometry — scrolling down to More Like This and back up
        // sometimes lost the top menu. A static section avoids that and also
        // matches the "richer, always-visible tech details on TV" feedback.
        #if os(tvOS)
        mediaSection
        #else
        collapsibleTechnicalDetailsSection
        #endif
    }

    private var collapsibleTechnicalDetailsSection: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.s) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    technicalDetailsExpanded.toggle()
                }
            } label: {
                HStack(spacing: AetherDesign.Spacing.xs) {
                    Text("Technical Details").textCase(.uppercase)
                        .font(AetherDesign.Typography.caption)
                        .foregroundStyle(AetherDesign.Palette.textTertiary)
                        .tracking(0.6)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(AetherDesign.Palette.textTertiary)
                        .rotationEffect(.degrees(technicalDetailsExpanded ? 0 : -90))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, AetherDesign.Spacing.m)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .premiumFocus()

            if technicalDetailsExpanded {
                VStack(spacing: 0) {
                    mediaInfoRows(current.mediaInfo)
                }
                .background(
                    AetherDesign.Materials.card,
                    in: RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                        .strokeBorder(AetherDesign.Palette.separator, lineWidth: 1)
                }
                .transition(.opacity)
            }
        }
    }

    /// Subtitle languages as a compact list — "English, Czech, Spanish +2".
    /// Localises the track's language code when present (Plex sends "eng" /
    /// "ces"), else falls back to the track's display title. Only the
    /// transcode path carries per-track subtitle metadata, so this stays
    /// hidden for direct-play items rather than showing a half-truth.
    private var subtitleSummary: String? {
        var seen = Set<String>()
        var ordered: [String] = []
        for track in current.subtitleTracks {
            guard let name = DetailFormatting.subtitleName(track) else { continue }
            if seen.insert(name.lowercased()).inserted { ordered.append(name) }
        }
        guard !ordered.isEmpty else { return nil }
        let shown = ordered.prefix(4).joined(separator: ", ")
        return ordered.count > 4 ? "\(shown) +\(ordered.count - 4)" : shown
    }


    /// Best-effort projected playback mode for the Media line, computed from
    /// container + quality choice. The server's actual decision is taken when
    /// Play is pressed; this is just a hint so the user knows what'll happen.
    private var playbackModeStatus: AetherStatus {
        let mode = projectedPlaybackMode
        switch mode {
        case .directPlay:   return .positive(mode.displayName)
        case .directStream: return .positive(mode.displayName)
        case .transcode:    return .muted(mode.displayName)
        }
    }

    private var projectedPlaybackMode: PlaybackDecisionMode {
        let container = current.mediaInfo?.container?.lowercased()
        let directPlayContainers: Set<String> = ["mp4", "m4v", "mov"]
        switch current.selectedQuality {
        case .original:
            if let container, directPlayContainers.contains(container) {
                return .directPlay
            }
            return .directStream
        case .convertAutomatically:
            return .directStream
        case .bitrate20Mbps1080p, .bitrate12Mbps1080p, .bitrate8Mbps1080p,
             .bitrate4Mbps720p, .bitrate2Mbps720p, .bitrate720kbps:
            return .transcode
        }
    }

}
