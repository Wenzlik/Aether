import SwiftUI
import AetherCore

/// Correct an SMB item's title & year (#213) and match it to TMDb. SMB files
/// carry no metadata — only a filename — so a mis-named release (e.g.
/// `the.film.2009.x265.mkv` vs the real title) won't match TMDb. This sheet lets
/// the user fix the title/year **and** search TMDb to pick the right result; on
/// save the correction is persisted as an override, the cached walk is dropped,
/// and the next browse re-matches TMDb with the corrected title → a fresh poster
/// / overview.
///
/// Available on tvOS too (free-form entry via the TV keyboard, plus the
/// search-and-pick flow, which is the easier path with a remote).
struct SMBMetadataEditSheet: View {
    let itemID: MediaID
    /// Currently displayed title / year, used to pre-fill when there's no saved
    /// override yet (so the user edits from what they see).
    let currentTitle: String
    let currentYear: Int?
    let onClose: () -> Void

    @Environment(AppSession.self) private var session

    @State private var title = ""
    @State private var yearText = ""
    @State private var hasOverride = false
    @State private var isSaving = false
    @State private var loaded = false

    // TMDb search-and-pick.
    @State private var candidates: [TMDbMetadata] = []
    @State private var isSearching = false
    @State private var chosenMatch: TMDbMetadata?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                Text("Edit Title & Year")
                    .font(AetherDesign.Typography.sectionTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)

                Text("SMB files have no metadata. Correct the title and year, or search TMDb and pick the right result.")
                    .font(AetherDesign.Typography.caption)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)

                detailsSection
                if session.isTMDbConfigured { matchSection }
                saveRow
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
        #if !os(tvOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        .task { await load() }
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

    // MARK: - Match

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

            if !candidates.isEmpty {
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

    private func load() async {
        guard !loaded else { return }
        loaded = true
        if let override = await session.smbOverride(for: itemID) {
            hasOverride = true
            title = override.title ?? currentTitle
            yearText = override.year.map(String.init) ?? currentYear.map(String.init) ?? ""
        } else {
            title = currentTitle
            yearText = currentYear.map(String.init) ?? ""
        }
    }

    private func search() async {
        isSearching = true
        defer { isSearching = false }
        candidates = await session.localMatchCandidates(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            year: Int(yearText.trimmingCharacters(in: .whitespaces)),
            isEpisode: false
        )
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
