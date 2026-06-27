import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import AetherCore

// #241 inc 5 — hero + metadata + cast + related: the related rail, episode parent
// navigation, hero title block, metadata / genre rows, media badges, source badge,
// and the Cast section. Split out of DetailView.swift (pure file split).
extension DetailView {

    // MARK: - More Like This

    /// Source-recommended similar titles. Each card navigates the per-source
    /// `MediaItem`, opening its own Detail. Hidden when the source returns none.
    @ViewBuilder
    var relatedRail: some View {
        if !related.isEmpty {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
                relatedHeader

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: AetherDesign.Spacing.l) {
                        ForEach(related) { rel in
                            NavigationLink(value: rel) {
                                AetherCard.poster(
                                    title: rel.title,
                                    posterURL: rel.posterURL,
                                    isWatched: rel.isWatched,
                                    netflixLogoURL: appSession.watchAvailability.netflixLogoURL(for: rel)
                                )
                                .frame(width: relatedPosterWidth)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, AetherDesign.Spacing.xs)
                }
                .aetherDetailFocusSection()
            }
        }
    }

    /// The "More Like This" title — plain text. Up-escape from the rail is handled
    /// by making the REAL section above it a focus section (the seasons rail on a
    /// series page; Available Sources / Technical Details on a movie page), rather
    /// than the earlier no-op header button (#266 — "do it properly").
    private var relatedHeader: some View {
        Text("More Like This")
            .font(AetherDesign.Typography.sectionTitle)
            .foregroundStyle(AetherDesign.Palette.textPrimary)
    }

    private var relatedPosterWidth: CGFloat {
        #if os(tvOS)
        220
        #else
        120
        #endif
    }

    // MARK: - Series loading

    /// Once the show's seasons (`children`) load, default browsing to the season
    /// the user is actually in — the first season with unwatched episodes (true
    /// On Deck), via the per-season `unwatchedEpisodeCount` — instead of always
    /// Season 1. Then compute the series' Next Up from that season's episodes.
    /// Idempotent — only runs while no season is selected, so re-running the
    /// `.task` after hydration doesn't reset the user's manual season choice.
    /// Episode-detail upward navigation: "Season N" and/or the series. Hidden
    /// when neither parent resolved (#282).
    @ViewBuilder
    var episodeParentNavigation: some View {
        if item.kind == .episode, parentSeason != nil || parentShow != nil {
            HStack(spacing: AetherDesign.Spacing.m) {
                if let parentSeason {
                    NavigationLink(value: parentSeason) {
                        parentNavLabel(DetailFormatting.seasonLabel(parentSeason), systemImage: "rectangle.stack")
                    }
                    .buttonStyle(.plain)
                }
                if let parentShow {
                    NavigationLink(value: parentShow) {
                        parentNavLabel(parentShow.title, systemImage: "tv")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func parentNavLabel(_ text: String, systemImage: String) -> some View {
        HStack(spacing: AetherDesign.Spacing.xs) {
            Image(systemName: systemImage)
            Text(text).lineLimit(1)
        }
        .font(AetherDesign.Typography.metadata)
        .foregroundStyle(AetherDesign.Palette.textPrimary)
        .padding(.horizontal, AetherDesign.Spacing.m)
        .padding(.vertical, AetherDesign.Spacing.s)
        .background(AetherDesign.Palette.surfaceElevated, in: Capsule())
        .premiumFocus()
    }

    /// Hero title. For an **episode** with a known series, the series name is the
    /// big title and "S1 • E2 - Episode Title" sits beneath it (how Infuse / Apple
    /// TV present an episode); movies / shows / seasons — and episodes missing a
    /// series title — show their own title (#266 Detail Phase 1). When the source
    /// carries a **clearLogo**, the title renders as the stylized wordmark art
    /// instead of plain text (#273) — text-first, swapping in only once the image
    /// has actually loaded, so titles without a logo never flash a placeholder.
    @ViewBuilder
    var heroTitleBlock: some View {
        if item.kind == .episode, let series = activeItem.seriesTitle, !series.isEmpty {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xxs) {
                Text(series)
                    .font(AetherDesign.Typography.heroTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                Text(DetailFormatting.episodeContext(activeItem))
                    .font(AetherDesign.Typography.sectionTitle)
                    .foregroundStyle(AetherDesign.Palette.textSecondary)
            }
        } else if let heroLogo {
            Image(uiImage: heroLogo)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: heroLogoMaxWidth, maxHeight: heroLogoMaxHeight, alignment: .leading)
                // Soft shadow so a light logo still separates from a bright
                // backdrop. (Predominantly dark logos fall back to text upstream.)
                .shadow(color: .black.opacity(0.55), radius: 10, y: 3)
                .accessibilityLabel(Text(activeItem.title))
        } else if item.kind == .season {
            // The formatter, not the raw title — a Czech-localized Plex sends
            // "7. řada", which should read "Season 7" (named seasons keep
            // their "S2 · Asylum" form).
            Text(DetailFormatting.seasonLabel(activeItem))
                .font(AetherDesign.Typography.heroTitle)
                .foregroundStyle(AetherDesign.Palette.textPrimary)
        } else {
            Text(activeItem.title)
                .font(AetherDesign.Typography.heroTitle)
                .foregroundStyle(AetherDesign.Palette.textPrimary)
        }
    }

    /// Logo caps — height-led (logos vary in aspect; `scaledToFit` follows).
    /// Generous on the 10-foot / spatial hero, compact on touch layouts.
    private var heroLogoMaxHeight: CGFloat {
        #if os(tvOS) || os(visionOS)
        140
        #else
        80
        #endif
    }

    private var heroLogoMaxWidth: CGFloat {
        #if os(tvOS) || os(visionOS)
        480
        #else
        280
        #endif
    }

    /// Dense single line, Infuse-style: "48 min • Jul 26, 2007 • [TV-14] • 1080p •
    /// DTS-HD MA 5.1" — runtime/date, the content-rating badge, then resolution +
    /// audio folded inline (they replace the old separate chip strip). The tech
    /// tail fills in when `mediaInfo` hydrates; the line reflows once, harmlessly.
    /// Community rating and TMDb rating are appended for movies/episodes (shows
    /// surface them in `seriesDetailsSection` instead).
    var metadataRow: some View {
        HStack(spacing: AetherDesign.Spacing.xs) {
            Text(metadataParts.joined(separator: " • "))
                .font(AetherDesign.Typography.metadata)
                .foregroundStyle(AetherDesign.Palette.textSecondary)
            if let rating = current.contentRating {
                metadataDot
                contentRatingBadge(rating)
            }
            if !item.kind.isContainer, !isShow {
                if let community = current.communityRating, community > 0 {
                    metadataDot
                    ratingChip(label: nil, value: community, systemImage: "star.fill")
                }
                if let tmdb = tmdbRating, tmdb > 0 {
                    metadataDot
                    ratingChip(label: "TMDb", value: tmdb, systemImage: nil)
                }
            }
            if !inlineTechParts.isEmpty {
                metadataDot
                Text(inlineTechParts.joined(separator: " • "))
                    .font(AetherDesign.Typography.metadata)
                    .foregroundStyle(AetherDesign.Palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Compact rating chip — star + value for community, label + value for TMDb.
    private func ratingChip(label: String?, value: Double, systemImage: String?) -> some View {
        HStack(spacing: 2) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
            }
            if let label {
                Text(label)
            }
            Text(String(format: "%.1f", value))
        }
        .font(AetherDesign.Typography.metadata)
        .foregroundStyle(AetherDesign.Palette.textSecondary)
    }

    /// The "•" separator used to splice the badge / tech tail into the line.
    private var metadataDot: some View {
        Text("•")
            .font(AetherDesign.Typography.metadata)
            .foregroundStyle(AetherDesign.Palette.textTertiary)
    }

    /// Resolution + HDR/DV + audio (codec + channels), folded into the metadata
    /// line — the glanceable subset of `mediaBadgeLabels` (the full breakdown
    /// stays in Technical Details). Empty until `mediaInfo` hydrates.
    private var inlineTechParts: [String] {
        guard let info = current.mediaInfo else { return [] }
        var parts: [String] = []
        if let resolution = info.videoResolution { parts.append(resolution) }
        if info.isDolbyVision {
            parts.append("Dolby Vision")
        } else if info.isHDR {
            parts.append("HDR")
        }
        if let audio = info.audioCodec?.uppercased() {
            if let channels = info.audioChannels {
                parts.append("\(audio) \(DetailFormatting.channelLabel(channels))")
            } else {
                parts.append(audio)
            }
        }
        return parts
    }

    /// The source's age/content classification as a thin-bordered badge —
    /// "PG-13", "TV-MA", "15" — sitting in the metadata line the way Infuse
    /// and Apple TV render it. Only shown when the source provided one.
    private func contentRatingBadge(_ rating: String) -> some View {
        Text(rating)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(AetherDesign.Palette.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(AetherDesign.Palette.textTertiary.opacity(0.6), lineWidth: 1)
            )
    }

    /// "Drama • Biography • History" — the genres line under the metadata, so the
    /// kind of title reads at a glance. Capped at four to avoid wrapping; hidden
    /// when the source carries none.
    @ViewBuilder
    var genresRow: some View {
        if !current.genres.isEmpty {
            Text(current.genres.prefix(4).joined(separator: " • "))
                .font(AetherDesign.Typography.metadata)
                .foregroundStyle(AetherDesign.Palette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var metadataParts: [String] {
        // Shows describe themselves by run span + season/episode counts, not a
        // single runtime: "2011–Present • 8 Seasons • 73 Episodes • Series".
        if item.kind == .show { return seriesMetadataParts }
        if item.kind == .season { return seasonMetadataParts }
        var parts: [String] = []
        if item.kind == .episode {
            // Episode: runtime + air date. The series name and "S1 • E2 - Title"
            // live in the hero title block, so no year or "Episode" label here.
            if let runtime = activeItem.runtime { parts.append(DetailFormatting.runtime(runtime)) }
            if let date = activeItem.releaseDate { parts.append(DetailFormatting.airDate(date, locale: locale)) }
        } else {
            // Movie: year + runtime. The kind label is dropped — it's obvious and
            // the Infuse-style reference omits it — keeping the line dense.
            if let year = activeItem.year { parts.append(String(year)) }
            if let runtime = activeItem.runtime { parts.append(DetailFormatting.runtime(runtime)) }
        }
        return parts
    }

    /// Season Detail metadata line: "2022 • 10 Episodes • 7/10 watched" (#245,
    /// #267). "Season N" appears only when the hero title is a *named* season
    /// (e.g. "Asylum") — when the title already reads "Season N", repeating it
    /// here said nothing. Reads `current`/`children` so hydrated counts fill in
    /// after the detail endpoint resolves.
    private var seasonMetadataParts: [String] {
        var parts: [String] = []
        if let number = current.seasonNumber, current.title != "Season \(number)" {
            parts.append("Season \(number)")
        }
        if let year = current.year { parts.append(String(year)) }
        let count = current.episodeCount ?? (children.isEmpty ? nil : children.count)
        if let count, count > 0 { parts.append("\(count) Episode\(count == 1 ? "" : "s")") }
        // Watch progress from the loaded episodes: "Watched" when done, else
        // "7/10 watched" once anything's been seen.
        if !children.isEmpty, children.allSatisfy({ $0.kind == .episode }) {
            let watched = children.filter(\.isWatched).count
            if watched == children.count {
                parts.append("Watched")
            } else if watched > 0 {
                parts.append("\(watched)/\(children.count) watched")
            }
        }
        return parts
    }

    /// Series metadata line. Reads `current` so the hydrated counts/status fill
    /// in after the detail endpoint resolves (the navigated list item often
    /// lacks them).
    private var seriesMetadataParts: [String] {
        let show = current
        var parts: [String] = []
        if let years = seriesYearText(show) { parts.append(years) }
        if let seasons = show.seasonCount, seasons > 0 {
            parts.append("\(seasons) Season\(seasons == 1 ? "" : "s")")
        }
        if let episodes = show.episodeCount, episodes > 0 {
            parts.append("\(episodes) Episode\(episodes == 1 ? "" : "s")")
        }
        parts.append("Series")
        return parts
    }

    /// "2011–2019" (ended), "2011–Present" (known continuing), or just "2011"
    /// when the end is unknown — Plex doesn't expose a status, so we never guess
    /// "Present" for it.
    private func seriesYearText(_ show: MediaItem) -> String? {
        guard let start = seriesStartYear(show) else { return nil }
        if let end = show.endYear, end != start { return "\(start)–\(end)" }
        if show.isContinuing == true { return "\(start)–Present" }
        return "\(start)"
    }

    private func seriesStartYear(_ show: MediaItem) -> Int? {
        if let year = show.year { return year }
        guard let date = show.releaseDate else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        return calendar.component(.year, from: date)
    }

    var isShow: Bool { item.kind == .show }

    /// Compact technical chips under the metadata — resolution, HDR / Dolby
    /// Vision, video codec, audio. Quality at a glance instead of buried in a
    /// table. Only shown once `MediaInfo` is hydrated.
    @ViewBuilder
    var mediaBadges: some View {
        let labels = mediaBadgeLabels
        if !labels.isEmpty {
            HStack(spacing: AetherDesign.Spacing.xs) {
                ForEach(labels, id: \.self) { AetherBadge($0) }
            }
            .padding(.top, AetherDesign.Spacing.xxs)
        }
    }

    private var mediaBadgeLabels: [String] {
        guard let info = current.mediaInfo else { return [] }
        var labels: [String] = []
        if let resolution = info.videoResolution { labels.append(resolution) }
        if info.isDolbyVision {
            labels.append("Dolby Vision")
        } else if info.isHDR {
            labels.append("HDR")
        }
        if let codec = info.videoCodec?.uppercased() { labels.append(codec) }
        if let audio = info.audioCodec?.uppercased() {
            if let channels = info.audioChannels {
                labels.append("\(audio) \(DetailFormatting.channelLabel(channels))")
            } else {
                labels.append(audio)
            }
        }
        // Surface Atmos as its own chip when the codec string advertises it
        // (e.g. "EAC3 (Atmos)"); harmless no-op when the source doesn't report it.
        if let audio = info.audioCodec?.lowercased(), audio.contains("atmos") {
            labels.append("Atmos")
        }
        return labels
    }

    // MARK: - Source badge

    /// The active source as a short uppercase tag (PLEX / JELLYFIN / OFFLINE /
    /// EMBY). Prefers the matching unified source's kind; falls back to the
    /// item's own source id. `nil` when it can't be determined.
    private var sourceLabel: String? {
        if let match = availableSources.first(where: { $0.item.id == activeItem.id }) {
            return match.kind.displayName.uppercased()
        }
        return MediaSourceKind(streaming: activeItem.id.source)?.displayName.uppercased()
    }

    @ViewBuilder
    var sourceBadge: some View {
        if let label = sourceLabel {
            Text(label)
                .font(.caption2.weight(.semibold))
                .tracking(0.5)
                .padding(.horizontal, AetherDesign.Spacing.xs)
                .padding(.vertical, 3)
                .background(AetherDesign.Palette.surfaceElevated, in: Capsule())
                .foregroundStyle(AetherDesign.Palette.textSecondary)
        }
    }

    // MARK: - Cast & Crew

    /// Cast for the screen — the item's own, else the parent show's (seasons
    /// rarely carry cast of their own, #267).
    private var displayCast: [CastMember] {
        current.cast.isEmpty ? fallbackCast : current.cast
    }

    /// Horizontal rail of cast + key crew with circular headshots — the biggest
    /// information-density gap vs. Infuse. Hidden when the source carries none.
    @ViewBuilder
    var castSection: some View {
        if !displayCast.isEmpty {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
                Text("Cast & Crew")
                    .font(AetherDesign.Typography.sectionTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: AetherDesign.Spacing.m) {
                        ForEach(displayCast) { member in castCard(member) }
                    }
                    .padding(.vertical, AetherDesign.Spacing.xxs)
                    .padding(.horizontal, 2)
                }
                // The rail is its own focus section so that on tvOS Up/Down from
                // any (now-tappable) cast card lands cleanly on the one element
                // above/below — no focus trap (#341, the constraint behind #249).
                .aetherDetailFocusSection()
            }
        }
    }

    /// One Cast & Crew card. Tappable → the person's filmography when the source
    /// gave us a queryable id (#341); otherwise a plain, non-interactive card
    /// (so it doesn't trap tvOS focus with a dead destination, per #249).
    @ViewBuilder
    private func castCard(_ member: CastMember) -> some View {
        if let entry = castPersonEntry(member) {
            NavigationLink(value: entry) {
                CastCardContent(member: member, size: castPhotoSize)
            }
            .buttonStyle(.plain)
        } else {
            CastCardContent(member: member, size: castPhotoSize)
        }
    }

    /// Build a `PersonEntry` (the value the universal person-grid destination
    /// takes) from a cast member, scoped to the shown item's source. `nil` when
    /// the source didn't supply a queryable person id.
    private func castPersonEntry(_ member: CastMember) -> PersonEntry? {
        guard let personID = member.personID, !personID.isEmpty else { return nil }
        let person = MediaPerson(
            id: MediaID(source: current.id.source, rawValue: personID),
            kind: .actor,
            name: member.name
        )
        return PersonEntry(name: member.name, kind: .actor, members: [person])
    }

    private var castPhotoSize: CGFloat {
        #if os(tvOS)
        180   // larger cards on TV — cast is a first-class browse destination
        #else
        84
        #endif
    }

    /// One cast/crew card. Reads `\.isFocused` directly so tvOS focus is
    /// unmistakable from across the room — a big scale jump, an accent ring on
    /// the headshot, a blue glow, and a lift. On platforms with no focus engine
    /// it renders the calm static card unchanged.
    private struct CastCardContent: View {
        let member: CastMember
        let size: CGFloat
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            VStack(spacing: AetherDesign.Spacing.xs) {
                photo
                Text(member.name)
                    .font(AetherDesign.Typography.caption.weight(.medium))
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                    .lineLimit(1)
                if let role = member.role {
                    Text(role)
                        .font(AetherDesign.Typography.caption)
                        .foregroundStyle(isFocused ? AetherDesign.Palette.textSecondary : AetherDesign.Palette.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(width: size)
            .multilineTextAlignment(.center)
            .scaleEffect(isFocused ? 1.18 : 1.0)
            .animation(AetherDesign.Motion.focus, value: isFocused)
        }

        private var photo: some View {
            ZStack {
                Circle().fill(AetherDesign.Palette.surfaceElevated)
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.38))
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
                if member.photoURL != nil {
                    CachedAsyncImage(url: member.photoURL, aspectRatio: 1, maxPixel: ArtworkTier.thumbnail.maxPixel)
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay {
                Circle().strokeBorder(AetherDesign.Palette.accent, lineWidth: isFocused ? 4 : 0)
            }
            .shadow(
                color: AetherDesign.Palette.accent.opacity(isFocused ? 0.7 : 0.0),
                radius: isFocused ? 24 : 0, y: isFocused ? 10 : 0
            )
        }
    }

}
