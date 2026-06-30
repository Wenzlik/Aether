import SwiftUI
import AetherCore

/// Correct an SMB item's title & year (#213) and match it to TMDb. SMB files
/// carry no metadata — only a filename — so a mis-named release (e.g.
/// `the.film.2009.x265.mkv` vs the real title) won't match TMDb. On save the
/// correction is persisted as an override, the cached walk is dropped, and the
/// next browse re-matches TMDb with the corrected title → a fresh poster /
/// overview.
///
/// **Confirm-first flow.** The filename parses correctly the vast majority of
/// the time, so the sheet leads with the *proposed* TMDb match (poster + title +
/// year) and a single **Use This Match** action — on tvOS that's one click, no
/// keyboard. Only when the proposal is wrong does the user drop into the manual
/// **Fix the match** step (editable title/year + a search-and-pick rail). When
/// TMDb is unconfigured or returns nothing, the sheet opens straight on the
/// manual step. See `docs/ux/DESIGN_PRINCIPLES.md` → lean-back / focus rules.
struct SMBMetadataEditSheet: View {
    let itemID: MediaID
    /// Currently displayed title / year, used to pre-fill when there's no saved
    /// override yet (so the user edits from what they see).
    let currentTitle: String
    let currentYear: Int?
    /// The source file's full path (host + share-relative path) — shown so the
    /// user can tell *exactly* which file they're correcting when a bad match
    /// makes the title/poster misleading. Marquee-scrolls if it overflows.
    let currentPath: String?
    /// Editing a show (not a movie/episode) → search TMDb as a **series** so the
    /// proposed matches are TV shows, and the saved correction (keyed by the show
    /// id) re-matches the whole series.
    var searchAsShow: Bool = false
    let onClose: () -> Void

    @Environment(AppSession.self) private var session

    /// Which surface the sheet is showing. `loading` runs the initial TMDb
    /// search; `confirm` offers the top result for one-tap acceptance; `edit`
    /// is the manual correction + search-and-pick fallback.
    private enum Step { case loading, confirm, edit }
    private enum FocusTarget { case primary }

    @State private var step: Step = .loading
    @State private var title = ""
    @State private var yearText = ""
    @State private var hasOverride = false
    @State private var isSaving = false

    // TMDb search-and-pick.
    @State private var candidates: [TMDbMetadata] = []
    @State private var isSearching = false
    @State private var chosenMatch: TMDbMetadata?

    @FocusState private var focus: FocusTarget?
    #if !os(tvOS)
    /// Open at `.large` so both the affirmative action *and* the "Edit Title &
    /// Year" fallback are visible without scrolling — at `.medium` the secondary
    /// button fell below the fold. The user can still drag down to `.medium`.
    @State private var detent: PresentationDetent = .large
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                Text(headerTitle)
                    .font(AetherDesign.Typography.sectionTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)

                filenameChip

                switch step {
                case .loading: loadingView
                case .confirm: confirmView
                case .edit:    editView
                }
            }
            .padding(AetherDesign.Spacing.l)
            .frame(maxWidth: AetherSheetLayout.maxContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .aetherScreenBackground()
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
                    .padding(AetherDesign.Spacing.m)
                    // Bigger tap target: `.plain` button hit-tests only the glyph
                    // without this — the X looked tiny / hard to hit (≥44pt HIG).
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        // Lean-back: land focus on the affirmative action so the common case is
        // one click with no rail-walking. Inert on iOS / visionOS (no focus engine).
        .defaultFocus($focus, .primary)
        #if !os(tvOS)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        #endif
        .task { await start() }
    }

    private var headerTitle: LocalizedStringKey {
        switch step {
        case .loading: return "Finding the best match…"
        case .confirm: return "Is this the right match?"
        case .edit:    return "Fix the match"
        }
    }

    @ViewBuilder private var filenameChip: some View {
        if let currentPath {
            // Show the full source path so a wrong match (misleading title /
            // poster) is still traceable back to the actual file. Long paths
            // marquee-scroll slowly instead of truncating.
            HStack(spacing: AetherDesign.Spacing.xs) {
                Image(systemName: "doc")
                MarqueeText(text: currentPath, font: AetherDesign.Typography.caption.monospaced())
            }
            .font(AetherDesign.Typography.caption.monospaced())
            .foregroundStyle(AetherDesign.Palette.textSecondary)
            .padding(AetherDesign.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AetherDesign.Materials.card, in: RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous))
        }
    }

    // MARK: - Loading

    /// Skeleton (never a spinner) shaped like the confirm hero, so the proposed
    /// match fades in without a layout jump.
    private var loadingView: some View {
        HStack(alignment: .top, spacing: AetherDesign.Spacing.l) {
            RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                .fill(AetherDesign.Palette.surfaceElevated)
                .frame(width: heroPosterWidth, height: heroPosterWidth * 1.5)
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.s) {
                skeletonBar(width: 280, height: 26)
                skeletonBar(width: 140, height: 16)
                skeletonBar(width: .infinity, height: 13)
                skeletonBar(width: .infinity, height: 13)
                skeletonBar(width: .infinity, height: 13)
            }
            Spacer(minLength: 0)
        }
        .redacted(reason: .placeholder)
    }

    private func skeletonBar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(AetherDesign.Palette.surfaceElevated)
            .frame(maxWidth: width == .infinity ? .infinity : width)
            .frame(height: height)
    }

    // MARK: - Confirm

    /// A large, couch-readable hero for the top match + a rail of alternatives
    /// (a "bigger offering" so a wrong top match isn't a dead end). Focus stays
    /// deliberately simple — the only directed focus is `defaultFocus` onto the
    /// primary button (tvOS focus is fragile; no per-item focus state, no
    /// focus-driven reflow).
    @ViewBuilder private var confirmView: some View {
        if let match = chosenMatch {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                HStack(alignment: .top, spacing: AetherDesign.Spacing.l) {
                    CachedAsyncImage(url: match.posterURL, aspectRatio: 2.0 / 3.0, maxPixel: ArtworkTier.detail.maxPixel)
                        .frame(width: heroPosterWidth, height: heroPosterWidth * 1.5)
                        .clipShape(RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous))

                    VStack(alignment: .leading, spacing: AetherDesign.Spacing.s) {
                        Text(match.title)
                            .font(AetherDesign.Typography.sectionTitle)
                            .foregroundStyle(AetherDesign.Palette.textPrimary)
                            .lineLimit(2)
                        if let meta = matchMetaLine(match) {
                            Text(meta)
                                .font(AetherDesign.Typography.metadata)
                                .foregroundStyle(AetherDesign.Palette.textSecondary)
                        }
                        if let overview = match.overview, !overview.isEmpty {
                            Text(overview)
                                .font(AetherDesign.Typography.body)
                                .foregroundStyle(AetherDesign.Palette.textTertiary)
                                .lineLimit(3)
                                .padding(.top, AetherDesign.Spacing.xs)
                        }

                        VStack(alignment: .leading, spacing: AetherDesign.Spacing.s) {
                            AetherButton(isSaving ? "Saving…" : "Use This Match", systemImage: "checkmark", role: .primary) {
                                guard !isSaving else { return }
                                Task { await use(match) }
                            }
                            .focused($focus, equals: .primary)

                            AetherButton("Edit Title & Year", systemImage: "pencil", role: .secondary) {
                                step = .edit
                            }
                        }
                        .padding(.top, AetherDesign.Spacing.m)
                    }
                    Spacer(minLength: 0)
                }

                alternativesRail
            }
        }
    }

    /// Alternatives to the top match. Big posters; clicking one adopts it
    /// directly — a remote click is deliberate, so there's no accidental commit,
    /// and nothing reflows as focus moves across the rail.
    @ViewBuilder private var alternativesRail: some View {
        let alternatives = Array(candidates.dropFirst())
        if !alternatives.isEmpty {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.s) {
                Text("MORE MATCHES")
                    .font(AetherDesign.Typography.caption)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
                    .tracking(0.6)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: AetherDesign.Spacing.m) {
                        ForEach(alternatives, id: \.tmdbID) { candidate in
                            alternativeCard(candidate)
                        }
                    }
                    .padding(.vertical, AetherDesign.Spacing.s)
                }
            }
        }
    }

    private func alternativeCard(_ candidate: TMDbMetadata) -> some View {
        Button {
            guard !isSaving else { return }
            Task { await use(candidate) }
        } label: {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
                CachedAsyncImage(url: candidate.posterURL, aspectRatio: 2.0 / 3.0, maxPixel: ArtworkTier.thumbnail.maxPixel)
                    .frame(width: altPosterWidth, height: altPosterWidth * 1.5)
                    .clipShape(RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous))
                    .premiumFocus(scale: 1.06)
                Text(candidate.title)
                    .font(AetherDesign.Typography.caption)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                    .lineLimit(1)
                if let y = candidate.year {
                    Text(String(y))
                        .font(AetherDesign.Typography.caption)
                        .foregroundStyle(AetherDesign.Palette.textTertiary)
                }
            }
            .frame(width: altPosterWidth)
        }
        .buttonStyle(.plain)
    }

    /// `2009 · ★ 7.8` — year and rating when present (TMDb gives us no genre /
    /// runtime here).
    private func matchMetaLine(_ match: TMDbMetadata) -> String? {
        var parts: [String] = []
        if let y = match.year { parts.append(String(y)) }
        if let r = match.rating, r > 0 { parts.append("★ \(String(format: "%.1f", r))") }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    // MARK: - Edit

    private var editView: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
            Text("SMB files have no metadata. Correct the title and year, then re-match — or search TMDb and pick the right result.")
                .font(AetherDesign.Typography.caption)
                .foregroundStyle(AetherDesign.Palette.textTertiary)

            detailsSection
            if session.isTMDbConfigured { matchSection }
            saveRow
        }
    }

    private var detailsSection: some View {
        AetherSettingsSection("Details") {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
                field("Title", text: $title, prompt: "Title")
                field("Year", text: $yearText, prompt: "Year", numeric: true)
            }
            .padding(AetherDesign.Spacing.m)
        }
    }

    private func field(_ label: LocalizedStringKey, text: Binding<String>, prompt: LocalizedStringKey, numeric: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
            Text(label).textCase(.uppercase)
                .font(AetherDesign.Typography.caption)
                .foregroundStyle(AetherDesign.Palette.textTertiary)
                .tracking(0.6)
            TextField(prompt, text: text)
                .textFieldStyle(.plain)
                .font(AetherDesign.Typography.body)
                .foregroundStyle(AetherDesign.Palette.textPrimary)
                .padding(AetherDesign.Spacing.m)
                .background(AetherDesign.Materials.card, in: RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                        .strokeBorder(AetherDesign.Palette.separator, lineWidth: 1)
                }
                #if os(iOS)
                .keyboardType(numeric ? .numberPad : .default)
                #endif
        }
    }

    /// Search TMDb by the title/year above and let the user pick the right
    /// result. Picking fills the title/year fields with the candidate's exact
    /// values, so the saved override re-matches to that result on the next walk.
    private var matchSection: some View {
        AetherSettingsSection("Match") {
            AetherSettingsRow(
                label: isSearching ? "Searching…" : "Find Match on TMDb",
                description: "Search by the title & year above, then pick the right result.",
                systemImage: "magnifyingglass",
                value: nil
            ) {
                guard !isSearching else { return }
                Task { await search() }
            }
            .disabled(isSearching)

            if candidates.isEmpty, didSearch, !isSearching {
                Text("No matches. Adjust the title or year and try again.")
                    .font(AetherDesign.Typography.caption)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
                    .padding(.horizontal, AetherDesign.Spacing.m)
                    .padding(.bottom, AetherDesign.Spacing.m)
            } else if !candidates.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AetherDesign.Spacing.m) {
                        ForEach(candidates, id: \.tmdbID) { candidate in
                            candidateCard(candidate)
                        }
                    }
                    .padding(.horizontal, AetherDesign.Spacing.m)
                    .padding(.bottom, AetherDesign.Spacing.m)
                }
            }
        }
    }

    @State private var didSearch = false

    private func candidateCard(_ candidate: TMDbMetadata) -> some View {
        let selected = chosenMatch?.tmdbID == candidate.tmdbID
        return Button {
            chosenMatch = candidate
            // Reflect the pick in the editable fields so the user sees what
            // they're applying (and the saved override re-matches it).
            title = candidate.title
            yearText = candidate.year.map(String.init) ?? ""
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                CachedAsyncImage(url: candidate.posterURL, aspectRatio: 2.0 / 3.0, maxPixel: ArtworkTier.thumbnail.maxPixel)
                    .frame(width: 92, height: 138)
                    .clipShape(RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                            .strokeBorder(selected ? AetherDesign.Palette.accent : .clear, lineWidth: 3)
                    }
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(AetherDesign.Palette.accent)
                                .padding(4)
                        }
                    }
                    .premiumFocus(scale: 1.06)
                Text(candidate.title)
                    .font(AetherDesign.Typography.caption)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                    .lineLimit(1)
                if let y = candidate.year {
                    Text(String(y))
                        .font(AetherDesign.Typography.caption)
                        .foregroundStyle(AetherDesign.Palette.textTertiary)
                }
            }
            .frame(width: 92)
        }
        .buttonStyle(.plain)
    }

    private var saveRow: some View {
        VStack(spacing: AetherDesign.Spacing.s) {
            AetherButton(isSaving ? "Saving…" : "Save & Re-match", systemImage: "checkmark", role: .primary) {
                guard !isSaving else { return }
                Task { await save() }
            }
            if hasOverride {
                AetherButton("Reset to Detected", role: .destructive) {
                    Task { await reset() }
                }
            }
        }
        .padding(.top, AetherDesign.Spacing.s)
    }

    // MARK: - Layout

    /// The big confirm-step poster — sized to read from couch distance on tvOS.
    private var heroPosterWidth: CGFloat {
        #if os(tvOS)
        260
        #else
        140
        #endif
    }

    /// Alternatives-rail poster — smaller than the hero, still couch-readable.
    private var altPosterWidth: CGFloat {
        #if os(tvOS)
        150
        #else
        100
        #endif
    }

    // MARK: - Actions

    /// Pre-fill from any saved override (else the displayed title/year), then run
    /// the initial TMDb search to populate the confirm step. Falls through to the
    /// manual step when TMDb is off or returns nothing.
    private func start() async {
        if let override = await session.smbOverride(for: itemID) {
            hasOverride = true
            title = override.title ?? currentTitle
            yearText = override.year.map(String.init) ?? currentYear.map(String.init) ?? ""
        } else {
            title = currentTitle
            yearText = currentYear.map(String.init) ?? ""
        }

        guard session.isTMDbConfigured else { step = .edit; return }

        isSearching = true
        candidates = await session.localMatchCandidates(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            year: Int(yearText.trimmingCharacters(in: .whitespaces)),
            isEpisode: searchAsShow
        )
        isSearching = false
        didSearch = true
        chosenMatch = candidates.first
        step = candidates.isEmpty ? .edit : .confirm
    }

    private func search() async {
        isSearching = true
        defer { isSearching = false }
        candidates = await session.localMatchCandidates(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            year: Int(yearText.trimmingCharacters(in: .whitespaces)),
            isEpisode: searchAsShow
        )
        didSearch = true
    }

    /// Accept a candidate from the confirm step: adopt its exact title/year and
    /// persist, so the next walk re-matches to it.
    private func use(_ candidate: TMDbMetadata) async {
        title = candidate.title
        yearText = candidate.year.map(String.init) ?? ""
        await save()
    }

    private func save() async {
        isSaving = true
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let year = Int(yearText.trimmingCharacters(in: .whitespaces))
        let override = SMBMetadataStore.Override(
            title: trimmedTitle.isEmpty ? nil : trimmedTitle,
            year: year
        )
        await session.saveSMBOverride(override.isEmpty ? nil : override, for: itemID)
        isSaving = false
        onClose()
    }

    private func reset() async {
        await session.saveSMBOverride(nil, for: itemID)
        onClose()
    }
}

// MARK: - Marquee

/// A single line of text that, when wider than its container, slowly scrolls
/// back and forth so the whole string is readable without truncation. Static
/// (left-aligned) when it fits.
private struct MarqueeText: View {
    let text: String
    var font: Font

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var animate = false

    private var overflow: CGFloat { max(0, textWidth - containerWidth) }

    var body: some View {
        // An invisible single-line copy drives the row height and reports the
        // available (container) width; the visible copy keeps its full intrinsic
        // width, overflows, and scrolls — clipped to the container.
        Text(text)
            .font(font)
            .lineLimit(1)
            .opacity(0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { g in
                    Color.clear.preference(key: MarqueeContainerWidthKey.self, value: g.size.width)
                }
            )
            .overlay(alignment: .leading) {
                Text(text)
                    .font(font)
                    .lineLimit(1)
                    .fixedSize()
                    .background(
                        GeometryReader { g in
                            Color.clear.preference(key: MarqueeTextWidthKey.self, value: g.size.width)
                        }
                    )
                    .offset(x: (overflow > 0 && animate) ? -overflow : 0)
            }
            .clipped()
            .onPreferenceChange(MarqueeContainerWidthKey.self) { containerWidth = $0 }
            .onPreferenceChange(MarqueeTextWidthKey.self) { textWidth = $0 }
            .onChange(of: overflow) { _, new in restartAnimation(overflow: new) }
            .onAppear { restartAnimation(overflow: overflow) }
            .accessibilityLabel(text)
    }

    private func restartAnimation(overflow: CGFloat) {
        animate = false
        guard overflow > 0 else { return }
        // ~22 pt/s — a slow, readable crawl — with a pause at each end.
        let duration = max(4, Double(overflow) / 22)
        withAnimation(.linear(duration: duration).delay(1.2).repeatForever(autoreverses: true)) {
            animate = true
        }
    }
}

private struct MarqueeContainerWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct MarqueeTextWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
