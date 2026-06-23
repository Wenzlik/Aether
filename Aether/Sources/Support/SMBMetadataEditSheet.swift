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
    /// The source filename — shown so the user can tell *which* file they're
    /// correcting when a bad match makes the title/poster misleading.
    let currentFilename: String?
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
            }
            .buttonStyle(.plain)
        }
        // Lean-back: land focus on the affirmative action so the common case is
        // one click with no rail-walking. Inert on iOS / visionOS (no focus engine).
        .defaultFocus($focus, .primary)
        #if !os(tvOS)
        .presentationDetents([.medium, .large])
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
        if let currentFilename {
            // Show the source filename so a wrong match (misleading title /
            // poster) is still traceable back to the actual file.
            HStack(spacing: AetherDesign.Spacing.xs) {
                Image(systemName: "doc")
                Text(currentFilename)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .font(AetherDesign.Typography.caption.monospaced())
            .foregroundStyle(AetherDesign.Palette.textSecondary)
            .padding(AetherDesign.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AetherDesign.Materials.card, in: RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous))
        }
    }

    // MARK: - Loading

    /// Skeleton (never a spinner) shaped like the confirm card, so the proposed
    /// match fades in without a layout jump.
    private var loadingView: some View {
        HStack(alignment: .top, spacing: AetherDesign.Spacing.m) {
            RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                .fill(AetherDesign.Palette.surfaceElevated)
                .frame(width: posterWidth, height: posterWidth * 1.5)
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.s) {
                skeletonBar(width: 180, height: 22)
                skeletonBar(width: 110, height: 14)
                skeletonBar(width: .infinity, height: 12)
                skeletonBar(width: .infinity, height: 12)
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

    @ViewBuilder private var confirmView: some View {
        if let match = chosenMatch {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                HStack(alignment: .top, spacing: AetherDesign.Spacing.m) {
                    CachedAsyncImage(url: match.posterURL, aspectRatio: 2.0 / 3.0, maxPixel: ArtworkTier.thumbnail.maxPixel)
                        .frame(width: posterWidth, height: posterWidth * 1.5)
                        .clipShape(RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous))

                    VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
                        Text(match.title)
                            .font(AetherDesign.Typography.cardTitle)
                            .foregroundStyle(AetherDesign.Palette.textPrimary)
                            .lineLimit(2)
                        if let meta = matchMetaLine(match) {
                            Text(meta)
                                .font(AetherDesign.Typography.metadata)
                                .foregroundStyle(AetherDesign.Palette.textSecondary)
                        }
                        if let overview = match.overview, !overview.isEmpty {
                            Text(overview)
                                .font(AetherDesign.Typography.caption)
                                .foregroundStyle(AetherDesign.Palette.textTertiary)
                                .lineLimit(4)
                                .padding(.top, AetherDesign.Spacing.xxs)
                        }
                    }
                    Spacer(minLength: 0)
                }

                VStack(spacing: AetherDesign.Spacing.s) {
                    AetherButton(isSaving ? "Saving…" : "Use This Match", systemImage: "checkmark", role: .primary) {
                        guard !isSaving else { return }
                        Task { await use(match) }
                    }
                    .focused($focus, equals: .primary)

                    AetherButton("Edit Details", systemImage: "pencil", role: .secondary) {
                        step = .edit
                    }
                }
            }
        }
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

    private var posterWidth: CGFloat {
        #if os(tvOS)
        160
        #else
        120
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
            isEpisode: false
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
            isEpisode: false
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
