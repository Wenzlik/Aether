import SwiftUI
import AetherCore

// #241 inc 4 — the show / seasons / episodes presentation cluster, split out of
// DetailView.swift (pure file split, no behavior change). These are `extension
// DetailView` members; the three entry points read from the main file
// (`childrenSection`, `seriesContent`, `nextUpCard`) are `internal`, the rest
// stay file-private. Cross-file reads (children, episodeResume, focus/preview
// state, source, current, …) were flipped `private` → `internal` in DetailView.swift.
extension DetailView {

    // MARK: - Children (seasons / episodes)

    // `internal`: called from the layout builders in DetailView.swift.
    @ViewBuilder
    var childrenSection: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            Text(childrenTitle)
                .font(AetherDesign.Typography.sectionTitle)
                .foregroundStyle(AetherDesign.Palette.textPrimary)

            if isLoadingChildren {
                AetherLoadingState(.inline)
            } else if children.isEmpty {
                Text("Nothing here yet.")
                    .font(AetherDesign.Typography.body)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
            } else if item.kind == .show {
                seasonsRail
            } else {
                episodesList
            }
        }
    }

    private var childrenTitle: String {
        item.kind == .show ? "Seasons" : "Episodes"
    }

    /// Season poster cards run a touch wider on the 10-foot UI so the named
    /// "S2 · Asylum" labels have room to breathe over two lines (#263).
    private var seasonCardWidth: CGFloat {
        #if os(tvOS)
        return 180
        #else
        return 140
        #endif
    }

    private var seasonsRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: AetherDesign.Spacing.m) {
                ForEach(children) { season in
                    NavigationLink(value: season) {
                        AetherCard.poster(
                            title: DetailFormatting.seasonLabel(season),
                            posterURL: season.posterURL,
                            isWatched: (season.unwatchedEpisodeCount ?? 1) == 0,
                            // Named seasons ("S2 · Asylum") need a second line so
                            // they don't clip to "Seaso…" on the 10-foot UI (#263).
                            titleLineLimit: 2
                        )
                        .frame(width: seasonCardWidth)
                        .seasonCardFocus()
                    }
                    .buttonStyle(.plain)
                    .focused($focusedSeasonID, equals: season.id)
                }
            }
            .padding(.vertical, AetherDesign.Spacing.xs)
        }
        // tvOS: mark the horizontal rail as a focus section so Up escapes it
        // back to the tab bar (there's no focusable element above it on a show
        // detail). Without this, focus is trapped in the rail. Matches the
        // Home / Library rails; the episodes list is vertical so it doesn't need it.
        .aetherDetailFocusSection()
    }

    /// A titled rail of season poster cards on the show page — each pushes a
    /// dedicated Season Detail (#245). Used for multi-season shows; single-season
    /// shows render their episodes inline instead.
    private var seasonsSection: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            Text("Seasons")
                .font(AetherDesign.Typography.sectionTitle)
                .foregroundStyle(AetherDesign.Palette.textPrimary)
            seasonsRail
            #if os(tvOS)
            // Focus = Preview: a lightweight read-out of the season currently
            // under focus (Select still opens the dedicated Season Detail) (#266).
            seasonPreview
            #endif
        }
        #if os(tvOS)
        .onChange(of: focusedSeasonID) { _, id in
            if let id { previewSeasonID = id }
        }
        #endif
    }

    #if os(tvOS)
    /// The season the preview describes — the last-focused one, else the first.
    private var previewSeason: MediaItem? {
        children.first { $0.id == previewSeasonID } ?? children.first
    }

    /// Lightweight preview of the focused season on the Show page: name, year /
    /// episode count / progress, and a short overview — immediate context while
    /// browsing without leaving for the Season Detail (#266).
    @ViewBuilder
    private var seasonPreview: some View {
        if let season = previewSeason {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
                Text(DetailFormatting.seasonLabel(season))
                    .font(AetherDesign.Typography.cardTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                if let meta = seasonPreviewMeta(season) {
                    Text(meta)
                        .font(AetherDesign.Typography.metadata)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                }
                if let summary = season.summary, !summary.isEmpty {
                    Text(summary)
                        .font(AetherDesign.Typography.body)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .animation(AetherDesign.Motion.hero, value: previewSeasonID)
        }
    }

    /// "2017 • 11 Episodes • 7/11 watched" — year, episode count, watch progress.
    private func seasonPreviewMeta(_ season: MediaItem) -> String? {
        var parts: [String] = []
        if let year = season.year { parts.append(String(year)) }
        if let count = season.episodeCount, count > 0 {
            parts.append("\(count) Episode\(count == 1 ? "" : "s")")
            if let unwatched = season.unwatchedEpisodeCount {
                if unwatched == 0 {
                    parts.append("Watched")
                } else if count - unwatched > 0 {
                    parts.append("\(count - unwatched)/\(count) watched")
                }
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }
    #endif

    @ViewBuilder
    private var episodesList: some View {
        #if os(tvOS)
        episodeRail(children)
        #else
        LazyVStack(spacing: AetherDesign.Spacing.m) {
            ForEach(children) { episode in
                NavigationLink(value: episode) {
                    episodeRow(episode)
                }
                .buttonStyle(.plain)
            }
        }
        #endif
    }

    private func episodeRow(_ episode: MediaItem) -> some View {
        HStack(alignment: .top, spacing: AetherDesign.Spacing.m) {
            CachedAsyncImage(
                url: episode.backdropURL(.still) ?? episode.posterURL(.thumbnail),
                aspectRatio: 16.0 / 9.0,
                maxPixel: ArtworkTier.still.maxPixel
            )
                .frame(width: 150)
                // Same watched treatment as the poster cards — dimming + WATCHED
                // wordmark + gold ribbon (compact for the small still) (#280).
                .watchedArtwork(episode.isWatched, display: watchedDisplay, compact: true)
                .clipShape(RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous))
                // In-progress: a resume bar across the bottom of the still (#260).
                .overlay(alignment: .bottom) { episodeProgressBar(episode) }

            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xxs) {
                Text(episode.title)
                    .font(AetherDesign.Typography.cardTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                    .lineLimit(2)
                if let resume = episodeResume[episode.id], !episode.isWatched {
                    Text("Resume \(DetailFormatting.position(resume.position))")
                        .font(AetherDesign.Typography.caption)
                        .foregroundStyle(AetherDesign.Palette.accent)
                } else if let runtime = episode.runtime {
                    Text(DetailFormatting.runtime(runtime))
                        .font(AetherDesign.Typography.caption)
                        .foregroundStyle(AetherDesign.Palette.textTertiary)
                }
                if let summary = episode.summary {
                    Text(summary)
                        .font(AetherDesign.Typography.caption)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// A thin resume bar across the bottom of an episode still when it's
    /// partially watched (#260) — so in-progress episodes are obvious in a list.
    @ViewBuilder
    private func episodeProgressBar(_ episode: MediaItem) -> some View {
        if let resume = episodeResume[episode.id], !episode.isWatched, let runtime = episode.runtime {
            let total = DetailFormatting.seconds(runtime)
            let fraction = total > 0 ? min(1, max(0, DetailFormatting.seconds(resume.position) / total)) : 0
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.25))
                    Capsule().fill(AetherDesign.Palette.accent)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 4)
            .padding(.horizontal, AetherDesign.Spacing.xs)
            .padding(.bottom, AetherDesign.Spacing.xs)
        }
    }

    #if os(tvOS)
    // MARK: - tvOS episode rail (Detail Phase 2)

    /// Wide 16:9 still cards, like the Infuse "Season N" rail.
    private var episodeStillWidth: CGFloat { 320 }

    /// "2. Ladies Room" — ordinal-prefixed episode title for the still rail.
    private func episodeOrdinalTitle(_ episode: MediaItem) -> String {
        if let number = episode.episodeNumber { return "\(number). \(episode.title)" }
        return episode.title
    }

    /// Resume time when in-progress, else air date, else runtime.
    private func episodeCaption(_ episode: MediaItem) -> String {
        if let resume = episodeResume[episode.id], !episode.isWatched {
            return "Resume \(DetailFormatting.position(resume.position))"
        }
        if let date = episode.releaseDate { return DetailFormatting.airDate(date, locale: locale) }
        if let runtime = episode.runtime { return DetailFormatting.runtime(runtime) }
        return ""
    }

    /// tvOS episode browsing: a horizontal rail of 16:9 stills (ordinal title +
    /// resume/date caption), mirroring the Infuse "Season N" rail instead of a
    /// tall vertical list. Each still keeps its watched marker + in-progress bar.
    private func episodeRail(_ episodes: [MediaItem]) -> some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: AetherDesign.Spacing.l) {
                    ForEach(episodes) { episode in
                        NavigationLink(value: episode) { episodeStillCard(episode) }
                            .buttonStyle(.plain)
                            .focused($focusedEpisodeID, equals: episode.id)
                    }
                }
                .padding(.vertical, AetherDesign.Spacing.xs)
            }
            .aetherDetailFocusSection()

            // Focus = Preview: browsing the rail reads out the focused episode
            // below it (synopsis, runtime, air date, resume) — the stills alone
            // often look identical when a source has no per-episode art (#267).
            episodePreview(episodes)
        }
        .onChange(of: focusedEpisodeID) { _, id in
            if let id { previewEpisodeID = id }
        }
    }

    /// Lightweight preview of the focused episode under the rail. Falls back to
    /// the first episode so the space never sits empty.
    @ViewBuilder
    private func episodePreview(_ episodes: [MediaItem]) -> some View {
        if let episode = episodes.first(where: { $0.id == previewEpisodeID }) ?? episodes.first {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
                Text(episodeOrdinalTitle(episode))
                    .font(AetherDesign.Typography.cardTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                if let meta = episodePreviewMeta(episode) {
                    Text(meta)
                        .font(AetherDesign.Typography.metadata)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                }
                if let summary = episode.summary, !summary.isEmpty {
                    Text(summary)
                        .font(AetherDesign.Typography.body)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .animation(AetherDesign.Motion.hero, value: previewEpisodeID)
        }
    }

    /// "50m • Sep 26, 2017 • Resume 12:30" / "… • Watched" — the preview's
    /// glanceable second line.
    private func episodePreviewMeta(_ episode: MediaItem) -> String? {
        var parts: [String] = []
        if let runtime = episode.runtime { parts.append(DetailFormatting.runtime(runtime)) }
        if let date = episode.releaseDate { parts.append(DetailFormatting.airDate(date, locale: locale)) }
        if let resume = episodeResume[episode.id], !episode.isWatched {
            parts.append("Resume \(DetailFormatting.position(resume.position))")
        } else if episode.isWatched {
            parts.append("Watched")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    /// Built on `AetherCard` so the still wears the **same** watched marker as
    /// posters — the bold gold corner ribbon, not a small checkmark — and the
    /// same prominent progress bar for in-progress episodes (#266 feedback).
    private func episodeStillCard(_ episode: MediaItem) -> some View {
        AetherCard(
            title: episodeOrdinalTitle(episode),
            subtitle: episodeCaption(episode),
            posterURL: episode.backdropURL(.still) ?? episode.posterURL(.thumbnail),
            aspectRatio: 16.0 / 9.0,
            progress: episodeProgressFraction(episode),
            isWatched: episode.isWatched,
            titleLineLimit: 1
        )
        .frame(width: episodeStillWidth)
    }

    /// Watched fraction for an in-progress (not-yet-watched) episode, else `nil`
    /// so `AetherCard` shows no progress bar.
    private func episodeProgressFraction(_ episode: MediaItem) -> Double? {
        guard let resume = episodeResume[episode.id], !episode.isWatched,
              let runtime = episode.runtime else { return nil }
        let total = DetailFormatting.seconds(runtime)
        guard total > 0 else { return nil }
        return min(1, max(0, DetailFormatting.seconds(resume.position) / total))
    }
    #endif

    // MARK: - Series layout (Next Up → Season Selector → Episodes → Details)

    /// The dedicated TV-show body. `children` here are the show's *seasons*; the
    /// selected season's episodes live in `seasonEpisodes` and render inline, so
    /// the user never navigates into a season just to see its episodes.
    // `internal`: the show body, composed by the layout builders in DetailView.swift.
    @ViewBuilder
    var seriesContent: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
            if isLoadingChildren && children.isEmpty {
                AetherLoadingState(.inline)
            } else {
                // Unified action cluster (#382): the show's primary action is a
                // single "▶ S1E1 · Pilot" pill that plays the on-deck episode,
                // beside the borderless Favorite icon — collapsing the old "NEXT
                // UP" card (a navigate-to-episode tile) into one Infuse-style
                // row. Full-width focus section so Up from ANY season card lands
                // here — section-to-section focus uses the section frames, not
                // the card geometry, so it works from Season 1 through Season N
                // (#266 feedback). Pairs with the seasons rail's own focus section.
                showActionCluster
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .aetherDetailFocusSection()
                if children.count > 1 {
                    // Multi-season: a rail of season poster cards that push a
                    // dedicated Season Detail (#245), instead of an inline
                    // selector + flat episode list.
                    seasonsSection
                } else {
                    // Single-season: skip the pointless drill and show the lone
                    // season's episodes inline.
                    seasonEpisodesSection
                }
                if let summary = activeItem.summary {
                    Text(summary)
                        .font(AetherDesign.Typography.body)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 720, alignment: .leading)
                }
                relatedRail
                seriesDetailsSection
                // Full-width focus column so Down from any More Like This card
                // lands here at any scroll offset — the section above the rail is
                // the seasons rail (already full-width); below is this (#359).
                if availableSources.count > 1 {
                    sourceSwitcher
                        .aetherDetailColumn()
                }
            }
        }
    }

    /// The show's unified action cluster (#382): a primary pill that plays the
    /// on-deck episode (newest in-progress, else the one after the last watched —
    /// `OnDeck.next`), beside the borderless Favorite icon when the source
    /// supports it. Replaces the old "NEXT UP" navigate-to-episode card. The pill
    /// routes through `EpisodeAutoplayRoute` so one tap plays while still reusing
    /// the episode's own, well-tested Detail playback path — `NavigationLink`,
    /// not a `Button`, so it's focusable on tvOS and reachable by the remote.
    /// Hidden until the on-deck episode resolves.
    @ViewBuilder
    private var showActionCluster: some View {
        if let episode = nextUpEpisode {
            HStack(spacing: AetherDesign.Spacing.m) {
                NavigationLink(value: EpisodeAutoplayRoute(item: episode)) {
                    AetherButtonLabel(
                        title: showPlayLabel(for: episode),
                        systemImage: "play.fill",
                        role: .primary
                    )
                }
                .buttonStyle(.plain)
                if source?.supportsFavorites == true {
                    AetherIconButton(
                        systemImage: isFavorite ? "heart.fill" : "heart",
                        accessibilityLabel: isFavorite ? "Remove from favorites" : "Add to favorites",
                        isActive: isFavorite
                    ) {
                        Task { await viewModel.toggleFavorite() }
                    }
                }
                // SMB shows carry no metadata — let the user correct the series
                // title/year here (the whole-show edit), which re-matches every
                // episode (#213). The per-episode pencil lives on episode rows.
                if isSMBSource(activeItem.id.source) {
                    AetherIconButton(systemImage: "pencil", accessibilityLabel: "Edit title and year") {
                        presentedSelector = .smbEditMetadata
                    }
                }
                // Identify a mis/unidentified Jellyfin series ("Season Unknown")
                // against the server's providers. The action row (with the
                // compact Identify button) isn't shown for shows, so it lives
                // here on the show header.
                if isJellyfinSource(activeItem.id.source) {
                    AetherIconButton(systemImage: "wand.and.stars", accessibilityLabel: "Identify on Jellyfin") {
                        presentedSelector = .identifyJellyfin
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// The on-deck episode pill label: "S1E1 · Pilot" to start fresh, or
    /// "S2E4 · Continue" when that episode is already in progress (#382). The
    /// episode code / title aren't translatable; "Continue" is resolved here so
    /// it localizes even though it's interpolated into the string.
    private func showPlayLabel(for episode: MediaItem) -> String {
        if nextUpResume != nil, let s = episode.seasonNumber, let e = episode.episodeNumber {
            return "S\(s)E\(e) · " + String(localized: "Continue")
        }
        return DetailFormatting.episodeLabel(episode)
    }

    /// "On Deck"-style card: thumbnail + episode code + title, with a resume
    /// caption when there's a saved position. Tapping opens the episode's detail
    /// (where Resume / Play / Download already live), so playback stays on the
    /// well-tested episode path.
    // `internal`: rendered by the movie/compact layout builders in DetailView.swift.
    @ViewBuilder
    var nextUpCard: some View {
        if let episode = nextUpEpisode {
            NavigationLink(value: episode) {
                HStack(spacing: AetherDesign.Spacing.m) {
                    CachedAsyncImage(
                        url: episode.backdropURL(.still) ?? episode.posterURL(.thumbnail),
                        aspectRatio: 16.0 / 9.0,
                        maxPixel: ArtworkTier.still.maxPixel
                    )
                        .frame(width: 160)
                        .clipShape(RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous))

                    VStack(alignment: .leading, spacing: AetherDesign.Spacing.xxs) {
                        Text(nextUpResume != nil ? "CONTINUE WATCHING" : "NEXT UP")
                            .font(AetherDesign.Typography.caption)
                            .foregroundStyle(AetherDesign.Palette.accent)
                        Text(DetailFormatting.episodeLabel(episode))
                            .font(AetherDesign.Typography.cardTitle)
                            .foregroundStyle(AetherDesign.Palette.textPrimary)
                            .lineLimit(2)
                        if let resume = nextUpResume {
                            Text("Resume from \(DetailFormatting.position(resume.position))")
                                .font(AetherDesign.Typography.caption)
                                .foregroundStyle(AetherDesign.Palette.textSecondary)
                        } else if let runtime = episode.runtime {
                            Text(DetailFormatting.runtime(runtime))
                                .font(AetherDesign.Typography.caption)
                                .foregroundStyle(AetherDesign.Palette.textTertiary)
                        }
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(AetherDesign.Palette.accent)
                }
                .padding(AetherDesign.Spacing.m)
                .background(
                    AetherDesign.Palette.surface,
                    in: RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 720, alignment: .leading)
            // tvOS: isolate so Up exits to the tab bar and Down reaches the
            // season selector / episodes instead of trapping focus.
            .aetherDetailFocusSection()
        }
    }

    @ViewBuilder
    private var seasonEpisodesSection: some View {
        if isLoadingEpisodes {
            AetherLoadingState(.inline)
        } else if !seasonEpisodes.isEmpty {
            #if os(tvOS)
            episodeRail(seasonEpisodes)
            #else
            LazyVStack(spacing: AetherDesign.Spacing.m) {
                ForEach(seasonEpisodes) { episode in
                    NavigationLink(value: episode) {
                        episodeRow(episode)
                    }
                    .buttonStyle(.plain)
                }
            }
            #endif
        }
    }

    /// The "Metadata" block: genres, rating, first-aired, status — surfaced now
    /// that both connectors plumb them through. Hidden entirely when empty.
    @ViewBuilder
    private var seriesDetailsSection: some View {
        let rows = seriesDetailRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.s) {
                Text("Details")
                    .font(AetherDesign.Typography.sectionTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                ForEach(rows, id: \.label) { row in
                    HStack(alignment: .top, spacing: AetherDesign.Spacing.m) {
                        Text(row.label)
                            .foregroundStyle(AetherDesign.Palette.textTertiary)
                            .frame(width: 110, alignment: .leading)
                        Text(row.value)
                            .foregroundStyle(AetherDesign.Palette.textSecondary)
                        Spacer(minLength: 0)
                    }
                    .font(AetherDesign.Typography.body)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    private var seriesDetailRows: [(label: String, value: String)] {
        let show = current
        var rows: [(label: String, value: String)] = []
        if !show.genres.isEmpty {
            rows.append((label: "Genres", value: show.genres.joined(separator: ", ")))
        }
        if let rating = show.communityRating {
            rows.append((label: "Community", value: String(format: "%.1f", rating)))
        }
        if let rating = tmdbRating ?? show.tmdbRating {
            rows.append((label: "TMDb", value: String(format: "%.1f", rating)))
        }
        if let aired = firstAiredText(show) {
            rows.append((label: "First Aired", value: aired))
        }
        if let status = seriesStatusText(show) {
            rows.append((label: "Status", value: status))
        }
        return rows
    }

    private func firstAiredText(_ show: MediaItem) -> String? {
        guard let date = show.releaseDate else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    private func seriesStatusText(_ show: MediaItem) -> String? {
        if show.isContinuing == true { return "Continuing" }
        if show.isContinuing == false || show.endYear != nil { return "Ended" }
        return nil
    }
}

// MARK: - Focus helpers
//
// `aetherDetailFocusSection()` / `aetherDetailColumn()` are `internal extension
// View` in DetailView.swift, so they're visible here. `seasonCardFocus()` +
// `SeasonCardFocus` live here (file-private) since the seasons rail is their only
// user (#241 inc 4).
private extension View {
    /// Bolder, couch-visible focus for season cards — a brighter accent glow and
    /// extra lift on top of the card's own focus (#266 feedback). tvOS only.
    @ViewBuilder
    func seasonCardFocus() -> some View {
        #if os(tvOS)
        modifier(SeasonCardFocus())
        #else
        self
        #endif
    }
}

#if os(tvOS)
private struct SeasonCardFocus: ViewModifier {
    @Environment(\.isFocused) private var isFocused
    func body(content: Content) -> some View {
        content
            .scaleEffect(isFocused ? 1.08 : 1.0)
            .shadow(
                color: AetherDesign.Palette.accent.opacity(isFocused ? 0.9 : 0),
                radius: isFocused ? 30 : 0,
                y: isFocused ? 12 : 0
            )
            .zIndex(isFocused ? 1 : 0)
            .animation(AetherDesign.Motion.focus, value: isFocused)
    }
}
#endif
