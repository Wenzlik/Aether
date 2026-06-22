import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import AetherCore

// #241 inc 5 — layout composers: the scroll / wide / two-column scaffolding, the
// movie hero / banner variants, scrims and the cinematic background. Split out of
// DetailView.swift (pure file split, no behavior change).
extension DetailView {

    // MARK: - Detail content

    var scrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                // Hero: edge-to-edge backdrop with the title + metadata + badges
                // stacked *below* it (not overlaid), so wide layouts don't push
                // the text into a side gutter beside a letterboxed image.
                VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
                    // Hero artwork now comes from the full-screen cinematic
                    // background (#290) — reserve the band height so the title
                    // sits below it, over the art, with no second backdrop.
                    // On iPhone, shows use a shorter band so the Continue
                    // Watching / Next Up card and Seasons aren't pushed below
                    // the fold (#337) — the resume action is a series' primary CTA.
                    Color.clear
                        .frame(height: compactHeroBandHeight)

                    VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
                        heroTitleBlock
                        metadataRow
                        genresRow
                    }
                    .padding(.horizontal, AetherDesign.Spacing.l)
                }

                if isShow {
                    // Dedicated TV-show layout: Next Up → Season Selector →
                    // Episodes → Overview → Details.
                    seriesContent
                        .padding(.horizontal, AetherDesign.Spacing.l)
                } else {
                    // Layout order (Apple-TV / Infuse style): Hero → Actions →
                    // Playback → Overview → Media Information → (children).
                    if !item.kind.isContainer {
                        actionRow
                            .padding(.horizontal, AetherDesign.Spacing.l)
                    }

                    episodeParentNavigation
                        .padding(.horizontal, AetherDesign.Spacing.l)

                    if !item.kind.isContainer, current.streamURL != nil {
                        playbackSection
                            .padding(.horizontal, AetherDesign.Spacing.l)
                            .frame(maxWidth: 720, alignment: .leading)
                    }

                    if let summary = item.summary {
                        AetherExpandableText(summary)
                            .padding(.horizontal, AetherDesign.Spacing.l)
                            .frame(maxWidth: 720, alignment: .leading)
                    }

                    // tvOS reaches the full technical details via the info icon
                    // in the action row → a focused, scrollable sheet — the
                    // inline section was clipped + competed with primary content
                    // (#281). Other platforms keep it inline (collapsed).
                    #if !os(tvOS)
                    if !item.kind.isContainer, current.mediaInfo != nil {
                        technicalDetailsSection
                            .padding(.horizontal, AetherDesign.Spacing.l)
                            .frame(maxWidth: 720, alignment: .leading)
                    }
                    #endif

                    // Only meaningful when the title exists on more than one source.
                    if availableSources.count > 1 {
                        sourceSwitcher
                            .padding(.horizontal, AetherDesign.Spacing.l)
                            .frame(maxWidth: 720, alignment: .leading)
                    }

                    // Season detail (browsed into directly): Next Up + episode list.
                    if item.kind.isContainer {
                        if item.kind == .season {
                            nextUpCard
                                .padding(.horizontal, AetherDesign.Spacing.l)
                        }
                        childrenSection
                            .padding(.horizontal, AetherDesign.Spacing.l)
                    }

                    // Cast & Crew sits below the primary actions / overview /
                    // sources (#247) — valuable, but not competing with them.
                    // Seasons fall back to the parent show's cast (#267).
                    if item.kind != .show {
                        castSection
                            .padding(.horizontal, AetherDesign.Spacing.l)
                    }
                }
            }
            // Pin the column to the viewport's leading edge. Without this the
            // VStack sizes to its widest child; the instant any child resolves
            // wider than the screen, a leading-aligned VStack with no width
            // constraint gets centered and its left edge — "Episodes", the
            // leading halves of the stills — slides off the iPad-portrait
            // screen. `movieContent` avoids this by anchoring its hero to
            // `size.width`; `wideContent` via an explicit pin. `scrollContent`
            // was the only layout missing one (the iPad-portrait episode clip).
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, AetherDesign.Spacing.xxl)
        }
    }

    // MARK: - Wide hero layout (tvOS / landscape / visionOS wide)

    /// Wide when the surface is landscape-ish and roomy: tvOS always; iPad
    /// landscape, iPhone landscape, and wide visionOS windows. iPhone/iPad
    /// portrait fall back to the vertical `scrollContent`.
    func isWideLayout(_ size: CGSize) -> Bool {
        #if os(tvOS)
        return true
        #else
        return size.width > size.height && size.width >= 600
        #endif
    }

    /// Apple-TV / Infuse-style detail: the backdrop fills the background; a
    /// dark scrim keeps the left content column readable; title, actions,
    /// overview and the playback rows sit on top, visible immediately.
    var wideContent: some View {
        ZStack(alignment: .topLeading) {
            // Backdrop comes from the full-screen cinematic background (#290) now;
            // keep just the readability scrim over it for the left content column.
            wideScrim
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                    // Primary content stays in the readable left column…
                    VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                        heroTitleBlock
                        metadataRow
                        genresRow

                        if !item.kind.isContainer {
                            actionRow
                        }

                        episodeParentNavigation

                        if let summary = activeItem.summary {
                            if item.kind.isContainer {
                                Text(summary)
                                    .font(AetherDesign.Typography.body)
                                    .foregroundStyle(AetherDesign.Palette.textSecondary)
                                    .lineLimit(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                synopsis(summary)
                            }
                        }

                        // Season page: "continue this season" one click away —
                        // and, as a full-width focus section, the Up target for
                        // the episode rail below (#267).
                        if item.kind == .season {
                            nextUpCard
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .aetherDetailFocusSection()
                        }

                        if !item.kind.isContainer, current.streamURL != nil {
                            playbackSection
                        }
                        #if !os(tvOS)
                        if !item.kind.isContainer, current.mediaInfo != nil {
                            technicalDetailsSection
                        }
                        #endif
                        if availableSources.count > 1 {
                            sourceSwitcher
                        }
                    }
                    .frame(maxWidth: wideColumnWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Episodes have no rail between this column and Cast & Crew, so
                    // make the (full-width) column a focus section → Up from any
                    // cast card lands here at any scroll offset (#359). Containers
                    // (seasons) opt out: their episodes rail already brackets cast,
                    // and the nested Next-Up section (#266) must stay the rail's Up
                    // target rather than being shadowed by an outer column section.
                    .aetherDetailFocusSection(when: !item.kind.isContainer)
                    .padding(.horizontal, AetherDesign.Spacing.xl)

                    // Seasons / Episodes rail breaks out of the left column on
                    // tvOS so it uses the full screen width (#266) — the text
                    // stays readable on the left, the rail spans the screen.
                    if item.kind.isContainer {
                        childrenSection
                            #if os(tvOS)
                            .padding(.leading, AetherDesign.Spacing.xl)
                            #else
                            .frame(maxWidth: wideColumnWidth, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, AetherDesign.Spacing.xl)
                            #endif
                    }

                    // …but Cast & Crew sits last (#247) and, on tvOS, breaks out
                    // of the column so the rail uses the full screen width.
                    // Seasons show it too — their own cast when the source has
                    // one, else the parent show's (#267).
                    if item.kind != .show {
                        castSection
                            #if os(tvOS)
                            .padding(.leading, AetherDesign.Spacing.xl)
                            #else
                            .frame(maxWidth: wideColumnWidth, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, AetherDesign.Spacing.xl)
                            #endif
                    }
                }
                .padding(.top, AetherDesign.Spacing.xl)
                .padding(.bottom, AetherDesign.Spacing.xxl)
            }
        }
    }

    #if os(iOS)
    // MARK: - iPad landscape two-column layout (#379)

    /// Fixed trailing-column width — wide enough for a Cast headshot rail and
    /// the Technical Details rows, narrow enough to leave the primary content
    /// (title, actions, episode list) the roomy leading column.
    private var trailingColumnWidth: CGFloat { 360 }

    /// iPad full-screen landscape detail: the primary content stays in a roomy
    /// leading column, while the secondary detail (Technical Details, Cast &
    /// Crew) moves into a trailing column so the right half of the screen is
    /// used instead of sitting empty over a dark backdrop (#379). One shared
    /// vertical scroll; both columns are top-aligned. tvOS / visionOS keep the
    /// cinematic single-column `wideContent`.
    var twoColumnContent: some View {
        ZStack(alignment: .topLeading) {
            wideScrim
                .ignoresSafeArea()

            ScrollView {
                HStack(alignment: .top, spacing: AetherDesign.Spacing.xl) {
                    // Leading column — primary content (mirrors `wideContent`'s
                    // left column, minus the secondary sections moved right).
                    VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                        heroTitleBlock
                        metadataRow
                        genresRow

                        if !item.kind.isContainer {
                            actionRow
                        }

                        episodeParentNavigation

                        if let summary = activeItem.summary {
                            if item.kind.isContainer {
                                Text(summary)
                                    .font(AetherDesign.Typography.body)
                                    .foregroundStyle(AetherDesign.Palette.textSecondary)
                                    .lineLimit(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                synopsis(summary)
                            }
                        }

                        if item.kind == .season {
                            nextUpCard
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if !item.kind.isContainer, current.streamURL != nil {
                            playbackSection
                        }

                        if availableSources.count > 1 {
                            sourceSwitcher
                        }

                        // Episode list (season page) — the primary browse target,
                        // so it stays in the roomy leading column.
                        if item.kind.isContainer {
                            childrenSection
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Trailing column — secondary detail.
                    VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                        if !item.kind.isContainer, current.mediaInfo != nil {
                            technicalDetailsSection
                        }
                        if item.kind != .show {
                            castSection
                        }
                    }
                    .frame(width: trailingColumnWidth, alignment: .leading)
                }
                .padding(.horizontal, AetherDesign.Spacing.xl)
                .padding(.top, AetherDesign.Spacing.xl)
                .padding(.bottom, AetherDesign.Spacing.xxl)
            }
        }
    }
    #endif

    /// Left-anchored content column width on wide layouts — the artwork shows
    /// through on the trailing side, the text stays readable on the leading.
    private var wideColumnWidth: CGFloat {
        #if os(tvOS)
        820
        #else
        640
        #endif
    }

    /// Dark gradient over the backdrop: strong on the leading edge (where the
    /// content column lives) and along the bottom, fading toward the trailing
    /// artwork so the image still reads.
    private var wideScrim: some View {
        ZStack {
            LinearGradient(
                colors: [
                    AetherDesign.Palette.background.opacity(0.92),
                    AetherDesign.Palette.background.opacity(0.55),
                    AetherDesign.Palette.background.opacity(0.08)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            LinearGradient(
                colors: [
                    AetherDesign.Palette.background.opacity(0.75),
                    AetherDesign.Palette.background.opacity(0.0)
                ],
                startPoint: .bottom,
                endPoint: .center
            )
        }
        .ignoresSafeArea()
    }

    /// The server-resize tier for the full-screen hero backdrop. tvOS / visionOS
    /// fill a large display, so they request a 1080p tier; phone / iPad use the
    /// regular backdrop. Pair with `maxPixel` so the local cache doesn't shrink
    /// the large tier back down.
    /// Full-screen artwork background for the whole Detail page (#290): the
    /// title's backdrop crisp, or its poster blurred into atmosphere when no
    /// backdrop exists. `current` (not `activeItem`) so it tracks source
    /// switches + hydration.
    var cinematicDetailBackground: some View {
        let backdrop = current.backdropURL(heroBackdropTier)
        // On compact width (iPhone portrait) a 16:9 backdrop aspect-filled to
        // the full screen height crops ~75 % of the image. fitTop pins it at
        // its natural 16:9 ratio so the whole width of the backdrop is visible.
        // Blurred-poster fallback keeps full-screen (it's intentionally enlarged
        // atmosphere, not a frame-accurate image).
        let fitTop = hSizeClass == .compact && backdrop != nil
        return CinematicArtworkBackground(
            url: backdrop ?? current.posterURL(.detail),
            blurRadius: backdrop != nil ? 0 : 40,
            maxPixel: heroBackdropTier.maxPixel,
            fitTop: fitTop
        )
    }

    private var heroBackdropTier: ArtworkTier {
        #if os(tvOS) || os(visionOS)
        return .backdropLarge
        #else
        return .backdrop
        #endif
    }

    /// Reserved hero-band height in `scrollContent` (the `Color.clear` spacer
    /// the title sits below). On regular width it matches the backdrop; on
    /// iPhone, **shows** get a shorter band so the Continue Watching / Next Up
    /// card and Seasons rise toward the top instead of sitting below the fold
    /// (#337). Movies keep the taller cinematic band.
    private var compactHeroBandHeight: CGFloat {
        if hSizeClass == .regular { return backdropMaxHeight }
        return isShow ? 150 : 220
    }

    private var backdropMaxHeight: CGFloat {
        // Shows put their seasons rail directly below the hero. On tvOS the only
        // way to scroll is to move focus onto a focusable element (a season
        // card), so a tall backdrop that pushes the seasons off-screen traps
        // focus entirely — the user can't move, and Menu exits the app. Use a
        // shorter backdrop for containers (shows) so the seasons sit on-screen
        // and are reachable on first appearance. Movies keep the full hero.
        let isContainer = item.kind.isContainer
        #if os(tvOS)
        return isContainer ? 300 : 560
        #else
        return isContainer ? 240 : 420
        #endif
    }

    // MARK: - Movie layout (cinematic hero, every platform)

    /// The redesigned movie screen: a full-bleed backdrop hero with the title,
    /// metadata, source + capability badges, a short overview and the primary
    /// actions embedded over it — content-first, configuration second. Playback
    /// settings sit *below* the hero (most users never touch them), and the
    /// technical readout moves into the "More" menu.
    func movieContent(_ size: CGSize) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                // Cinematic surfaces (tvOS / visionOS / landscape) keep the
                // full-bleed hero with the actions embedded over the backdrop.
                // iPhone portrait gets an efficient banner: a shorter backdrop
                // band with the title / metadata / actions stacked *below* it,
                // so the first decision ("play this?") is reachable without
                // scrolling and the backdrop stops behaving like a poster.
                if isCinematicHero(size) {
                    movieHero(size)
                } else {
                    movieBanner(size)
                }

                // Below the hero — same order on every platform: what-it's-about,
                // then the richer sections, then discovery, with playback config
                // kept last (most users never touch it). §5: description follows
                // the actions, never precedes them.
                movieBelowHero
                    .padding(.horizontal, AetherDesign.Spacing.l)
            }
            .padding(.bottom, AetherDesign.Spacing.xxl)
        }
    }

    /// Below-hero section stack, shared by the cinematic and banner movie
    /// layouts. Description → Available Sources → Technical Details →
    /// More Like This → Playback settings (config dead last).
    /// Synopsis treatment: a 3-line teaser on tvOS (users browse visually from
    /// across the room and the expand control is another focus stop), expandable
    /// More/Less on touch + spatial.
    @ViewBuilder
    func synopsis(_ summary: String) -> some View {
        #if os(tvOS)
        Text(summary)
            .font(AetherDesign.Typography.body)
            .foregroundStyle(AetherDesign.Palette.textSecondary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
        #else
        AetherExpandableText(summary)
        #endif
    }

    @ViewBuilder
    private var movieBelowHero: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
            if let summary = activeItem.summary {
                synopsis(summary)
                    .frame(maxWidth: 720, alignment: .leading)
            }
            // Each focusable section that neighbours the More Like This / Cast
            // rails below is a full-width focus column, so Up/Down from any rail
            // card lands cleanly above/below at any scroll offset (#359).
            if availableSources.count > 1 {
                sourceSwitcher
                    .aetherDetailColumn()
            }
            #if !os(tvOS)
            if current.mediaInfo != nil {
                technicalDetailsSection
                    .aetherDetailColumn()
            }
            #endif
            relatedRail
            if current.streamURL != nil {
                playbackSection
                    .aetherDetailColumn()
            }
            // Cast & Crew last — below Related (#247).
            castSection
        }
    }

    /// True when the hero should be the full-bleed cinematic stage (actions
    /// embedded over the backdrop): tvOS / visionOS always, and any landscape
    /// surface. iPhone *portrait* (compact width) gets the banner instead;
    /// iPad portrait stays cinematic (it has the room and read well already).
    private func isCinematicHero(_ size: CGSize) -> Bool {
        #if os(tvOS) || os(visionOS)
        return true
        #else
        if size.width > size.height { return true }   // landscape → cinematic
        return hSizeClass != .compact                 // portrait: iPhone → banner, iPad → cinematic
        #endif
    }

    /// iPhone-portrait movie layout: a shorter backdrop *banner* with the title,
    /// metadata, genres, badges and the action row stacked beneath it (not
    /// overlaid). Prioritises information density over cinematic scale on a
    /// small display — Title · Metadata · Genres · Resume · Restart land above
    /// the fold.
    private func movieBanner(_ size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            // The full-screen cinematic background (#290) is the hero artwork
            // now — reserve the same height so the title sits over the lower
            // part of that art instead of stacking a second backdrop banner.
            Color.clear.frame(height: compactHeroHeight(size))

            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
                heroTitleBlock
                metadataRow
                genresRow
            }
            .padding(.horizontal, AetherDesign.Spacing.l)

            if !item.kind.isContainer {
                actionRow
                    .padding(.horizontal, AetherDesign.Spacing.l)
            }
        }
    }

    /// A short bottom fade on the banner backdrop so the title below it reads
    /// against the image edge without the heavy full-hero scrim.
    private var bannerScrim: some View {
        LinearGradient(
            colors: [.clear, AetherDesign.Palette.background.opacity(0.85)],
            startPoint: .center,
            endPoint: .bottom
        )
    }

    /// Banner height for iPhone portrait — a 16:9-ish band capped at roughly a
    /// third of the viewport, so it reads as a backdrop treatment rather than a
    /// full-screen poster (the §7 complaint).
    private func compactHeroHeight(_ size: CGSize) -> CGFloat {
        min(size.width * 9.0 / 16.0, size.height * 0.34)
    }

    private func movieHero(_ size: CGSize) -> some View {
        ZStack(alignment: .bottomLeading) {
            // Hero artwork comes from the full-screen cinematic background (#290);
            // reserve the stage height so the embedded actions sit at the bottom
            // of it, over the art, with no second backdrop image.
            Color.clear
                .frame(width: size.width, height: movieHeroHeight(size))

            VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
                heroTitleBlock

                HStack(spacing: AetherDesign.Spacing.s) {
                    Text(metadataParts.joined(separator: " • "))
                        .font(AetherDesign.Typography.metadata)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                    sourceBadge
                    Spacer(minLength: 0)
                }

                genresRow

                mediaBadges

                // Description moved out of the hero (§5): it now follows the
                // actions in `movieBelowHero`, so the play decision comes first.
                actionRow
            }
            .padding(AetherDesign.Spacing.l)
            .frame(maxWidth: movieHeroContentWidth, alignment: .leading)
        }
        .frame(width: size.width, height: movieHeroHeight(size), alignment: .bottomLeading)
        // tvOS: the hero is a full-width focus section so Up from the first
        // below-hero rail (More Like This) reaches the action row at ANY scroll
        // offset — section-to-section focus uses the section *frame* (full width
        // here), not the actions' capped geometry. This covers the single-source
        // movie with no Available Sources, where the hero is the rail's nearest
        // focusable neighbour (#359). No-op off tvOS → the visionOS hero (and its
        // first-use hint, #355) is untouched.
        .aetherDetailFocusSection()
    }

    /// Bottom-anchored dark gradient — keeps the embedded content readable in
    /// both portrait and landscape (unlike the wide layout's leading scrim).
    private var movieHeroScrim: some View {
        LinearGradient(
            colors: [
                .clear,
                AetherDesign.Palette.background.opacity(0.55),
                AetherDesign.Palette.background.opacity(0.96)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Hero height: most of the screen on tvOS / landscape (cinematic), a tall
    /// upper portion in portrait so the content still hints at scroll below.
    private func movieHeroHeight(_ size: CGSize) -> CGFloat {
        // Trimmed from the earlier 0.80–0.82: with the description no longer
        // embedded the hero needs less height, reclaiming vertical space for
        // the content below while staying cinematic on the big surfaces.
        #if os(tvOS)
        return size.height * 0.74
        #else
        // Landscape stays cinematic but a touch shorter; iPad portrait (the
        // only portrait surface still routed here) gets a calmer half-screen.
        return size.width > size.height ? size.height * 0.72 : size.height * 0.52
        #endif
    }

    /// Cap the embedded content column on roomy surfaces so lines stay readable;
    /// fills the width on a phone.
    private var movieHeroContentWidth: CGFloat {
        #if os(tvOS)
        900
        #else
        640
        #endif
    }

}
