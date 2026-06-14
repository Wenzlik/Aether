import SwiftUI
import AetherCore

/// Detail screen for a library item. Movies (and episodes) hydrate to expose
/// **Audio / Subtitle / Quality** pickers and rich metadata, then play with the
/// chosen tracks — for Plex this matters because the universal transcoder bakes
/// the *selected* track into the stream, so the choice must be made here, before
/// playback resolves (the player can't switch a muxed track afterwards).
/// Containers (shows / seasons) drill down through the shared
/// `navigationDestination(for: MediaItem.self)`.
struct MediaDetailView: View {
    let session: MacSession
    let item: MediaItem
    /// Resolve + open a player window for a playable (non-container) item.
    let onPlay: (MediaItem) -> Void

    /// Hydrated, track-selectable working copy of `item` (movies / episodes).
    /// `nil` until the per-item fetch lands; falls back to the thin `item`.
    @State private var working: MediaItem?
    @State private var children: [MediaItem] = []
    @State private var isLoading = false
    @State private var showTechnical = false

    /// The item the screen renders + plays: the hydrated copy once loaded.
    private var current: MediaItem { working ?? item }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if !item.kind.isContainer {
                    Button { onPlay(current) } label: {
                        Label("Play", systemImage: "play.fill").frame(maxWidth: 220)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)

                    playbackOptions
                }
                if let overview = current.summary, !overview.isEmpty {
                    Text(overview)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 720, alignment: .leading)
                }
                if !current.genres.isEmpty {
                    Text(current.genres.joined(separator: " · "))
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !item.kind.isContainer {
                    technicalSection
                }
                if !current.cast.isEmpty {
                    castSection
                }
                if item.kind.isContainer {
                    childrenSection
                }
            }
            .padding(28)
            .frame(maxWidth: 1040)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .background {
            // iOS-style cinematic hero: the title's backdrop, blurred, behind
            // the content (with the component's own readability scrim).
            CinematicArtworkBackground(
                url: current.backdropURL ?? current.posterURL,
                blurRadius: 40
            )
            .ignoresSafeArea()
        }
        .navigationTitle(item.title)
        .task(id: item.id) { await load() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            CachedAsyncImage(url: current.posterURL, aspectRatio: 2.0 / 3.0)
                .frame(width: 210)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
            VStack(alignment: .leading, spacing: 10) {
                // Title as the clearLogo wordmark when the source has one, else
                // the title text (iOS-style "special text").
                if let logo = current.logoURL() {
                    CachedAsyncImage(url: logo)
                        .frame(maxWidth: 360, maxHeight: 88, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(current.title).font(.system(size: 40, weight: .bold))
                }
                HStack(spacing: 10) {
                    if let year = current.year { Text(String(year)) }
                    if let runtime = current.runtime { Text(DetailFormatting.runtime(runtime)) }
                    if let rating = current.contentRating { Text(rating) }
                    if let community = current.communityRating {
                        Label(String(format: "%.1f", community), systemImage: "star.fill")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                if let badge = DetailFormatting.hdrBadge(current.mediaInfo) {
                    Text(badge)
                        .font(.caption.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.tint.opacity(0.2), in: Capsule())
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Playback options (Audio / Subtitles / Quality)

    @ViewBuilder
    private var playbackOptions: some View {
        if working == nil && !item.kind.isContainer && isLoading {
            ProgressView().controlSize(.small)
        } else if let work = working {
            GroupBox {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                    if !work.audioTracks.isEmpty {
                        optionRow("Audio", systemImage: "waveform") {
                            Picker("", selection: audioSelection) {
                                ForEach(work.audioTracks) { track in
                                    Text(track.displayTitle).tag(Optional(track.id))
                                }
                            }
                            .labelsHidden()
                        }
                    }
                    if !work.subtitleTracks.isEmpty {
                        optionRow("Subtitles", systemImage: "captions.bubble") {
                            Picker("", selection: subtitleSelection) {
                                Text("Off").tag(String?.none)
                                ForEach(work.subtitleTracks) { track in
                                    Text(DetailFormatting.subtitleName(track) ?? track.displayTitle)
                                        .tag(Optional(track.id))
                                }
                            }
                            .labelsHidden()
                        }
                    }
                    optionRow("Quality", systemImage: "slider.horizontal.3") {
                        Picker("", selection: qualitySelection) {
                            ForEach(PlaybackQuality.allCases, id: \.self) { q in
                                Text(q.displayName).tag(q)
                            }
                        }
                        .labelsHidden()
                    }
                }
            }
            .frame(maxWidth: 480)
        }
    }

    private func optionRow<Content: View>(_ label: String, systemImage: String, @ViewBuilder _ control: () -> Content) -> some View {
        GridRow {
            Label(label, systemImage: systemImage)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            control()
        }
    }

    // Bindings that rebuild the working item through the model's pure selection
    // transforms — `resolvePlayback` later PUTs these choices to the server.
    private var audioSelection: Binding<String?> {
        Binding(
            get: { current.selectedAudioTrackID },
            set: { id in
                guard let id, let track = current.audioTracks.first(where: { $0.id == id }) else { return }
                working = current.selectingAudioTrack(track)
            }
        )
    }

    private var subtitleSelection: Binding<String?> {
        Binding(
            get: { current.selectedSubtitleTrackID },
            set: { id in
                let track = id.flatMap { tid in current.subtitleTracks.first { $0.id == tid } }
                working = current.selectingSubtitleTrack(track)
            }
        )
    }

    private var qualitySelection: Binding<PlaybackQuality> {
        Binding(
            get: { current.selectedQuality },
            set: { working = current.selectingQuality($0) }
        )
    }

    // MARK: Technical details

    @ViewBuilder
    private var technicalSection: some View {
        let lines = [
            DetailFormatting.videoLine(current.mediaInfo),
            DetailFormatting.audioLine(current.mediaInfo),
            current.mediaInfo?.container.map { "Container: \($0.uppercased())" },
            current.mediaInfo?.fileSizeBytes.map { "Size: \(DetailFormatting.fileSize($0))" }
        ].compactMap { $0 }
        if !lines.isEmpty {
            DisclosureGroup("Technical Details", isExpanded: $showTechnical) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(lines, id: \.self) { Text($0) }
                }
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: 480)
        }
    }

    // MARK: Cast

    private var castSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cast").font(.title2.bold())
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(current.cast) { member in
                        VStack(spacing: 6) {
                            CachedAsyncImage(url: member.photoURL, aspectRatio: 1)
                                .frame(width: 72, height: 72)
                                .clipShape(Circle())
                            Text(member.name).font(.caption).lineLimit(1)
                            if let role = member.role {
                                Text(role).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .frame(width: 84)
                    }
                }
            }
        }
    }

    // MARK: Children (seasons / episodes)

    private let seasonColumns = [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 18, alignment: .top)]

    @ViewBuilder
    private var childrenSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AetherSectionHeader(title: item.kind == .show ? "Seasons" : "Episodes")
            if isLoading && children.isEmpty {
                ProgressView().padding(.vertical, 8)
            } else if item.kind == .show {
                // Seasons as a poster grid (wraps to multiple rows) — uses the
                // width instead of a tall scrolling list.
                LazyVGrid(columns: seasonColumns, spacing: 18) {
                    ForEach(children, id: \.id) { season in
                        NavigationLink(value: season) { seasonCard(season) }
                            .buttonStyle(.plain)
                    }
                }
            } else {
                // Episodes stay a list — they carry stills + descriptions.
                ForEach(children, id: \.id) { child in
                    HStack {
                        childRow(child)
                        Spacer()
                        Button { playChild(child) } label: { Image(systemName: "play.fill") }
                            .buttonStyle(.borderless)
                    }
                    Divider()
                }
            }
        }
    }

    private func seasonCard(_ season: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            CachedAsyncImage(url: season.posterURL ?? current.posterURL, aspectRatio: 2.0 / 3.0)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(season.title).font(.callout).lineLimit(1)
        }
    }

    private func childRow(_ child: MediaItem) -> some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: child.posterURL, aspectRatio: child.kind == .episode ? 16.0 / 9.0 : 2.0 / 3.0)
                .frame(width: child.kind == .episode ? 120 : 54)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(child.kind == .episode ? DetailFormatting.episodeLabel(child) : child.title)
                    .font(.body)
                if let summary = child.summary, child.kind == .episode, !summary.isEmpty {
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Load + play

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        if item.kind.isContainer {
            children = await session.children(of: item)
        } else {
            working = await session.hydratedItem(for: item)
        }
    }

    /// Episodes play straight from the list — hydrate + apply defaults first so
    /// they get the right audio/subtitle tracks like the movie Detail does.
    private func playChild(_ child: MediaItem) {
        Task { onPlay(await session.hydratedItem(for: child)) }
    }
}
