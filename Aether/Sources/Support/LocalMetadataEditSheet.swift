#if !os(tvOS)
import SwiftUI
import UniformTypeIdentifiers
import AetherCore

/// Edit a Local Library item's metadata + poster (#211). Opened from the pencil
/// action on a local movie/episode Detail screen. Pre-fills from the item's
/// *effective* values (override > TMDb match > filename inference) and writes
/// the user's corrections back as overrides — which win over the auto-match.
///
/// tvOS-gated: the editor needs `fileImporter` (no tvOS document picker) and
/// free-form text entry, matching how the Local Library import flow is gated.
struct LocalMetadataEditSheet: View {
    let itemID: String
    let onClose: () -> Void

    @Environment(AppSession.self) private var session

    @State private var stored: LocalLibraryStore.Item?
    @State private var title = ""
    @State private var yearText = ""
    @State private var isEpisode = false
    @State private var seasonText = ""
    @State private var episodeText = ""
    @State private var overview = ""

    // Poster: bytes chosen this session (not yet saved) + a live preview.
    @State private var pickedArtwork: Data?
    @State private var pickedPreview: Image?
    @State private var clearArtwork = false
    @State private var isImportingArtwork = false

    // TMDb re-match.
    @State private var candidates: [TMDbMetadata] = []
    @State private var isSearching = false
    @State private var chosenMatch: TMDbMetadata?

    @State private var isSaving = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                Text("Edit Metadata")
                    .font(AetherDesign.Typography.sectionTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)

                posterSection
                if session.isTMDbConfigured { matchSection }
                detailsSection
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
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .fileImporter(
            isPresented: $isImportingArtwork,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            pickedArtwork = data
            clearArtwork = false
            #if canImport(UIKit)
            pickedPreview = UIImage(data: data).map { Image(uiImage: $0) }
            #endif
        }
        .task { await load() }
    }

    // MARK: - Poster

    private var posterSection: some View {
        AetherSettingsSection("Poster") {
            HStack(spacing: AetherDesign.Spacing.m) {
                posterPreview
                    .frame(width: 80, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous))
                VStack(alignment: .leading, spacing: AetherDesign.Spacing.s) {
                    Group {
                        if pickedArtwork != nil {
                            Text("New poster selected")
                        } else {
                            Text("Choose a custom poster from your files.")
                        }
                    }
                    .font(AetherDesign.Typography.caption)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
                    Button("Choose Poster…") { isImportingArtwork = true }
                        .font(AetherDesign.Typography.body)
                        .foregroundStyle(AetherDesign.Palette.accent)
                        .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(AetherDesign.Spacing.m)
            if hasCustomArtwork && !clearArtwork && pickedArtwork == nil {
                AetherSettingsRow(label: "Remove Custom Poster", actionRole: .destructive) {
                    clearArtwork = true
                    pickedPreview = nil
                }
            }
        }
    }

    @ViewBuilder private var posterPreview: some View {
        if let pickedPreview {
            pickedPreview.resizable().scaledToFill()
        } else if !clearArtwork, let url = currentPosterURL {
            CachedAsyncImage(url: url, maxPixel: ArtworkTier.thumbnail.maxPixel)
        } else {
            posterPlaceholder
        }
    }

    private var posterPlaceholder: some View {
        RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
            .fill(AetherDesign.Palette.surfaceElevated)
            .overlay {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
            }
    }

    // MARK: - Match

    private var matchSection: some View {
        AetherSettingsSection("Match") {
            AetherSettingsRow(
                label: isSearching ? "Searching…" : "Find Match on TMDb",
                description: "Search by the title & year below, then pick the right result.",
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
            // Reflect the chosen match in the editable fields so the user sees
            // what they're applying (they can still tweak before saving).
            title = candidate.title
            yearText = candidate.year.map(String.init) ?? ""
            overview = candidate.overview ?? ""
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

    // MARK: - Details

    private var detailsSection: some View {
        AetherSettingsSection("Details") {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
                field("Title", text: $title, prompt: "Title")
                field("Year", text: $yearText, prompt: "Year", numeric: true)
                Toggle("This is a TV episode", isOn: $isEpisode)
                    .font(AetherDesign.Typography.body)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                    .tint(AetherDesign.Palette.accent)
                if isEpisode {
                    field("Season", text: $seasonText, prompt: "Season number", numeric: true)
                    field("Episode", text: $episodeText, prompt: "Episode number", numeric: true)
                }
                field("Overview", text: $overview, prompt: "Overview", multiline: true)
                Text("Leave a field blank to use the detected value.")
                    .font(AetherDesign.Typography.caption)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
            }
            .padding(AetherDesign.Spacing.m)
        }
    }

    private func field(_ label: LocalizedStringKey, text: Binding<String>, prompt: LocalizedStringKey, numeric: Bool = false, multiline: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
            Text(label).textCase(.uppercase)
                .font(AetherDesign.Typography.caption)
                .foregroundStyle(AetherDesign.Palette.textTertiary)
                .tracking(0.6)
            Group {
                if multiline {
                    TextField(prompt, text: text, axis: .vertical).lineLimit(3...8)
                } else {
                    TextField(prompt, text: text)
                }
            }
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

    // MARK: - Save

    private var saveRow: some View {
        VStack(spacing: AetherDesign.Spacing.s) {
            AetherButton(isSaving ? "Saving…" : "Save", systemImage: "checkmark", role: .primary) {
                guard !isSaving else { return }
                Task { await save() }
            }
            if hasOverrides {
                AetherButton("Reset to Match / Inferred", role: .destructive) {
                    Task { await reset() }
                }
            }
        }
        .padding(.top, AetherDesign.Spacing.s)
    }

    // MARK: - State helpers

    private var hasCustomArtwork: Bool { stored?.overrides?.artworkFilename != nil }
    private var hasOverrides: Bool { stored?.overrides != nil }
    private var currentPosterURL: URL? {
        guard let stored else { return nil }
        return session.localLibraryStore.artworkURL(for: stored) ?? stored.metadata?.posterURL
    }

    // MARK: - Actions

    private func load() async {
        guard let item = await session.localItem(for: itemID) else { onClose(); return }
        stored = item
        title = item.effectiveTitle
        yearText = item.effectiveYear.map(String.init) ?? ""
        isEpisode = item.effectiveIsEpisode
        seasonText = item.effectiveSeason.map(String.init) ?? ""
        episodeText = item.effectiveEpisode.map(String.init) ?? ""
        overview = item.effectiveOverview ?? ""
    }

    private func search() async {
        isSearching = true
        defer { isSearching = false }
        candidates = await session.localMatchCandidates(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            year: Int(yearText.trimmingCharacters(in: .whitespaces)),
            isEpisode: isEpisode
        )
    }

    private func save() async {
        guard let stored else { onClose(); return }
        isSaving = true

        // Apply a chosen candidate first, so it becomes the item's .metadata and
        // the override diff below is computed against the *new* match.
        if let chosenMatch {
            await session.applyLocalMatch(chosenMatch, for: itemID)
        }
        let match = chosenMatch ?? stored.metadata

        // Write a freshly-picked poster (versioned filename in the store).
        var artworkName = clearArtwork ? nil : stored.overrides?.artworkFilename
        if let pickedArtwork {
            artworkName = await session.saveLocalArtwork(pickedArtwork, for: itemID)
        }

        // Build overrides by diffing each field against its fallback (match →
        // inference); a field equal to the fallback stays nil ("fall back")
        // rather than freezing a redundant override.
        var ov = LocalLibraryStore.Item.Overrides()
        let titleVal = trimmedOrNil(title)
        ov.title = (titleVal != (match?.title ?? stored.title)) ? titleVal : nil
        let yearVal = Int(yearText.trimmingCharacters(in: .whitespaces))
        ov.year = (yearVal != (match?.year ?? stored.year)) ? yearVal : nil
        ov.isEpisode = (isEpisode != stored.isEpisode) ? isEpisode : nil
        if isEpisode {
            let s = Int(seasonText.trimmingCharacters(in: .whitespaces))
            ov.season = (s != stored.season) ? s : nil
            let e = Int(episodeText.trimmingCharacters(in: .whitespaces))
            ov.episode = (e != stored.episode) ? e : nil
        }
        let overviewVal = trimmedOrNil(overview)
        ov.overview = (overviewVal != (match?.overview)) ? overviewVal : nil
        // setOverrides replaces the WHOLE struct — carry the poster filename in
        // or it would be wiped.
        ov.artworkFilename = artworkName

        await session.saveLocalOverrides(ov.isEmpty ? nil : ov, for: itemID)
        isSaving = false
        onClose()
    }

    private func reset() async {
        await session.saveLocalOverrides(nil, for: itemID)
        onClose()
    }

    private func trimmedOrNil(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
#endif
