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
    @Environment(\.watchedDisplay) private var watchedDisplay

    /// Hydrated, track-selectable working copy of `item` (movies / episodes).
    /// `nil` until the per-item fetch lands; falls back to the thin `item`.
    @State private var working: MediaItem?
    @State private var children: [MediaItem] = []
    /// The show's On Deck episode (continue/next-up), for show containers only.
    @State private var nextUp: MediaItem?
    /// For an episode: its parent season + show, so you can navigate back up the
    /// hierarchy even when the episode was opened directly (e.g. Continue Watching).
    @State private var parentSeason: MediaItem?
    @State private var parentShow: MediaItem?
    @State private var isLoading = false
    /// Saved resume position (seconds) for a playable item — drives Resume.
    @State private var resumeAt: Double?
    /// Optimistic watched/favorite overrides so the buttons flip instantly.
    @State private var watchedOverride: Bool?
    @State private var favoriteOverride: Bool?

    /// The item the screen renders + plays: the hydrated copy once loaded.
    private var current: MediaItem { working ?? item }

    private var isWatched: Bool { watchedOverride ?? current.isFullyWatched }
    private var isFavorite: Bool { favoriteOverride ?? current.isFavorite }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                parentLinks
                header
                if !item.kind.isContainer {
                    primaryActions
                    controlsRow
                    // Desktop two-column: the description takes the width, with a
                    // right rail for Technical Details + the (collapsed) Playback
                    // Options — using the horizontal space rather than a narrow
                    // centre strip, and keeping the technical pickers out of the
                    // primary flow.
                    infoColumns
                } else {
                    descriptionBlock
                }
                if !current.cast.isEmpty { castSection }
                if item.kind == .show { nextUpSection }
                if item.kind.isContainer { childrenSection }
            }
            .padding(40)
            .frame(maxWidth: 1320)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .background {
            // iOS-style cinematic background: the title's **backdrop** fills the
            // whole screen, crisp (aspect-fill). A poster fallback (no backdrop)
            // gets blurred into atmosphere, like iOS. On top, a stronger vertical
            // scrim keeps the title (top) and description (bottom) readable over
            // bright backdrops.
            let backdrop = current.backdropURL
            ZStack {
                CinematicArtworkBackground(
                    url: backdrop ?? current.posterURL,
                    blurRadius: backdrop != nil ? 0 : 40
                )
                LinearGradient(
                    colors: [.black.opacity(0.55), .black.opacity(0.12),
                             .black.opacity(0.45), .black.opacity(0.8)],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .ignoresSafeArea()
        }
        .navigationTitle(item.title)
        // Reload on watched changes too (libraryToken bumps on mark watched), so
        // a season's episode rows + the show's Next Up reflect freshly-marked
        // state instead of a stale fetch.
        .task(id: "\(item.id.rawValue)-\(session.libraryToken)") { await load() }
        // Refresh the Resume position after the player closes (it bumps
        // resumeRevision on every write), so the button reflects where you
        // stopped — and the screen we return to after playback (#8) stays current.
        .task(id: session.resumeRevision) {
            guard !item.kind.isContainer else { return }
            resumeAt = await session.savedResumeSeconds(for: item)
        }
    }

    // MARK: Breadcrumb (episode → season → show)

    /// Up-navigation for an episode: tappable Series and Season, so an episode
    /// opened directly (Continue Watching) can still reach the season + show.
    @ViewBuilder
    private var parentLinks: some View {
        if item.kind == .episode, parentShow != nil || parentSeason != nil {
            HStack(spacing: 8) {
                if let show = parentShow {
                    NavigationLink(value: show) {
                        Label(show.title, systemImage: "chevron.left")
                    }
                    .buttonStyle(.link)
                }
                if let season = parentSeason {
                    Text("·").foregroundStyle(.tertiary)
                    NavigationLink(value: season) { Text(season.title) }
                        .buttonStyle(.link)
                }
            }
            .font(.callout)
            .lineLimit(1)
        }
    }

    // MARK: Header

    private var header: some View {
        // No small poster — the title's artwork already fills the screen as the
        // backdrop (#20), so the thumbnail was redundant. Just the title + meta.
        VStack(alignment: .leading, spacing: 14) {
            // Title as the clearLogo wordmark when the source has one, else the
            // title text (iOS-style "special text"). Scaled up for desktop.
            if let logo = current.logoURL() {
                CachedAsyncImage(url: logo)
                    .frame(maxWidth: 540, maxHeight: 150, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(current.title)
                    .font(.system(size: 56, weight: .bold))
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
            }
            HStack(spacing: 12) {
                if let year = current.year { Text(String(year)) }
                if let runtime = current.runtime { Text(DetailFormatting.runtime(runtime)) }
                if let rating = current.contentRating { Text(rating) }
                if let community = current.communityRating {
                    Label(String(format: "%.1f", community), systemImage: "star.fill")
                }
            }
            .font(.title3)
            .foregroundStyle(.secondary)
            if let badge = DetailFormatting.hdrBadge(current.mediaInfo) {
                Text(badge)
                    .font(.caption.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.tint.opacity(0.2), in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Play + controls

    /// The dominant action on the page. When partially watched, **Resume** leads
    /// (primary) with **Restart** secondary; otherwise a single big **Play**.
    @ViewBuilder
    private var primaryActions: some View {
        HStack(spacing: 14) {
            if let resumeAt, resumeAt > 1 {
                bigButton("Resume · \(timecode(resumeAt))", systemImage: "play.fill", prominent: true) {
                    Task { await session.play(current) }
                }
                bigButton("Restart", systemImage: "gobackward", prominent: false) {
                    Task { await session.play(current, startAt: 0) }
                }
            } else {
                bigButton("Play", systemImage: "play.fill", prominent: true) { onPlay(current) }
            }
        }
    }

    /// An oversized action button — Play/Resume should immediately draw the eye
    /// (Apple TV / Infuse presentation), so it's taller, wider, and bolder than a
    /// standard control.
    @ViewBuilder
    private func bigButton(_ title: String, systemImage: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        let label = Label(title, systemImage: systemImage)
            .font(.title3.weight(.semibold))
            .frame(minWidth: prominent ? 260 : 150)
            .padding(.vertical, 8)
        if prominent {
            Button(action: action) { label }
                .controlSize(.extraLarge)
                .buttonStyle(.borderedProminent)
                .tint(AetherMacTheme.accent)
        } else {
            Button(action: action) { label }
                .controlSize(.extraLarge)
                .buttonStyle(.bordered)
        }
    }

    /// Secondary controls from the other platforms: Mark Watched/Unwatched and
    /// (where the source supports it) Favorite. Optimistic so they flip on tap.
    private var controlsRow: some View {
        HStack(spacing: 12) {
            Button {
                let next = !isWatched
                watchedOverride = next
                Task { await session.markWatched(current, watched: next) }
            } label: {
                Label(isWatched ? "Watched" : "Mark as Watched",
                      systemImage: isWatched ? "checkmark.circle.fill" : "checkmark.circle")
            }
            .buttonStyle(.bordered)

            if session.canFavorite(current) {
                Button {
                    let next = !isFavorite
                    favoriteOverride = next
                    Task { await session.setFavorite(current, to: next) }
                } label: {
                    Label(isFavorite ? "Favorited" : "Favorite",
                          systemImage: isFavorite ? "heart.fill" : "heart")
                }
                .buttonStyle(.bordered)
            }
        }
        .controlSize(.large)
    }

    private func timecode(_ seconds: Double) -> String {
        let t = Int(seconds), h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    // MARK: Description + two-column desktop layout

    /// Overview + genres — allowed to run wide for easy reading (point 4).
    @ViewBuilder
    private var descriptionBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let overview = current.summary, !overview.isEmpty {
                Text(overview)
                    .font(.title3)
                    .foregroundStyle(.primary.opacity(0.9))
                    .lineSpacing(4)
            }
            if !current.genres.isEmpty {
                Text(current.genres.joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// Description on the left (wide), a Technical Details + Playback Options rail
    /// on the right — collapses to a single column on narrow windows.
    private var infoColumns: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 36) {
                descriptionBlock.frame(maxWidth: 720, alignment: .leading)
                infoSidebar.frame(width: 360)
            }
            VStack(alignment: .leading, spacing: 24) {
                descriptionBlock
                infoSidebar
            }
        }
    }

    /// Right rail: Technical Details (always shown — uses the desktop space) and
    /// the collapsible, advanced Playback Options.
    private var infoSidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            technicalCard
            playbackOptionsSection
        }
    }

    // MARK: Playback options (Audio / Subtitles / Quality) — advanced, collapsed

    @ViewBuilder
    private var playbackOptionsSection: some View {
        if working == nil && !item.kind.isContainer && isLoading {
            ProgressView().controlSize(.small)
        } else if let work = working {
            DisclosureGroup("Playback Options") {
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
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
    private var technicalCard: some View {
        let lines = [
            DetailFormatting.videoLine(current.mediaInfo),
            DetailFormatting.audioLine(current.mediaInfo),
            current.mediaInfo?.container.map { "Container: \($0.uppercased())" },
            current.mediaInfo?.fileSizeBytes.map { "Size: \(DetailFormatting.fileSize($0))" }
        ].compactMap { $0 }
        if !lines.isEmpty {
            // Always shown in the right rail (the desktop has the space), rather
            // than a collapsed disclosure buried in the main flow.
            VStack(alignment: .leading, spacing: 8) {
                Text("Technical Details")
                    .font(.headline)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(lines, id: \.self) { Text($0) }
                }
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                // Episodes stay a list — they carry stills + descriptions. The
                // row opens the episode's own Detail (#10); a trailing button is
                // the quick-play shortcut.
                ForEach(children, id: \.id) { child in
                    HStack {
                        NavigationLink(value: child) { childRow(child) }
                            .buttonStyle(.plain)
                        Spacer()
                        Button { playChild(child) } label: { Image(systemName: "play.fill") }
                            .buttonStyle(.borderless)
                    }
                    Divider()
                }
            }
        }
    }

    /// Show-level "Continue Watching / Next Up" (parity with iOS): the On Deck
    /// episode (in-progress, else the next after the last watched) as a landscape
    /// card with Play and a tap-through to its Detail.
    @ViewBuilder
    private var nextUpSection: some View {
        if let episode = nextUp {
            VStack(alignment: .leading, spacing: 12) {
                AetherSectionHeader(title: "Continue Watching")
                HStack(alignment: .top, spacing: 16) {
                    NavigationLink(value: episode) {
                        CachedAsyncImage(url: episode.backdropURL ?? episode.posterURL, aspectRatio: 16.0 / 9.0)
                            .frame(width: 220)
                            .watchedArtwork(episode.isFullyWatched, display: watchedDisplay, compact: true)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(DetailFormatting.episodeLabel(episode)).font(.headline)
                        if let summary = episode.summary, !summary.isEmpty {
                            Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                        Button { playChild(episode) } label: {
                            Label("Play", systemImage: "play.fill").frame(maxWidth: 160)
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func seasonCard(_ season: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            CachedAsyncImage(url: season.posterURL ?? current.posterURL, aspectRatio: 2.0 / 3.0)
                .watchedArtwork(season.isFullyWatched, display: watchedDisplay)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(season.title).font(.callout).lineLimit(1)
                .foregroundStyle(season.isFullyWatched ? .secondary : .primary)
        }
    }

    private func childRow(_ child: MediaItem) -> some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: child.posterURL, aspectRatio: child.kind == .episode ? 16.0 / 9.0 : 2.0 / 3.0)
                .frame(width: child.kind == .episode ? 120 : 54)
                // Reflect server watched state (synced cross-platform) with the
                // shared dim + checkmark treatment, so episodes already seen on
                // another device read as watched here too.
                .watchedArtwork(child.isFullyWatched, display: watchedDisplay, compact: true)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(child.kind == .episode ? DetailFormatting.episodeLabel(child) : child.title)
                    .font(.body)
                    .foregroundStyle(child.isFullyWatched ? .secondary : .primary)
                if let summary = child.summary, child.kind == .episode, !summary.isEmpty {
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if child.isFullyWatched {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .help("Watched")
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
            if item.kind == .show {
                nextUp = await session.onDeckEpisode(forShow: item)
            }
        } else {
            working = await session.hydratedItem(for: item)
            resumeAt = await session.savedResumeSeconds(for: item)
            if item.kind == .episode {
                let parents = await session.parents(of: item)
                parentSeason = parents.season
                parentShow = parents.show
            }
        }
    }

    /// Episodes play straight from the list — hydrate + apply defaults first so
    /// they get the right audio/subtitle tracks like the movie Detail does.
    private func playChild(_ child: MediaItem) {
        Task { onPlay(await session.hydratedItem(for: child)) }
    }
}
