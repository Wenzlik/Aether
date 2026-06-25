import SwiftUI
import AetherCore

/// Identify a mis- or unidentified Jellyfin title from the app instead of the
/// web dashboard (#identify). Jellyfin does the matching server-side: we ask its
/// metadata providers (`RemoteSearch`), show the candidates, and on confirm send
/// the chosen one back (`Apply`) so the server pulls full metadata + artwork and
/// every client sees the fix.
///
/// **Confirm-first.** The cleaned filename usually finds the right title, so the
/// sheet leads with the candidate list and a single tap per match — applying is
/// always a deliberate tap (no silent auto-commit, because it overwrites the
/// item server-side). The query (name + year) is editable for the cases the
/// filename parses badly.
struct JellyfinIdentifySheet: View {
    let itemID: MediaID
    /// Currently displayed title, used to seed the (cleaned) search query.
    let currentTitle: String
    let currentYear: Int?
    /// A show searches `/RemoteSearch/Series`, a movie `/RemoteSearch/Movie`.
    let kind: MediaItem.Kind
    let onClose: () -> Void

    @Environment(AppSession.self) private var session

    private enum Step { case loading, pick, applying }

    @State private var step: Step = .loading
    @State private var name = ""
    @State private var yearText = ""
    @State private var candidates: [JellyfinAPI.RemoteSearchResult] = []
    @State private var didSearch = false
    @State private var errorMessage: String?

    #if !os(tvOS)
    @State private var detent: PresentationDetent = .large
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                Text("Identify on Jellyfin")
                    .font(AetherDesign.Typography.sectionTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)

                Text("Search Jellyfin's metadata providers, then pick the right match. Jellyfin applies it to the server, so every client sees the fix.")
                    .font(AetherDesign.Typography.caption)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)

                querySection

                if let errorMessage {
                    Text(errorMessage)
                        .font(AetherDesign.Typography.metadata)
                        .foregroundStyle(AetherDesign.Palette.error)
                        .fixedSize(horizontal: false, vertical: true)
                }

                switch step {
                case .loading:  loadingView
                case .pick:     resultsView
                case .applying: applyingView
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
        #if !os(tvOS)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        #endif
        .task { await start() }
    }

    // MARK: - Query

    private var querySection: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            field("Title", text: $name, prompt: "Title")
            field("Year", text: $yearText, prompt: "Year", numeric: true)
            AetherButton(step == .loading ? "Searching…" : "Search", systemImage: "magnifyingglass", role: .secondary) {
                guard step != .loading else { return }
                Task { await search() }
            }
            .disabled(step == .loading || name.trimmingCharacters(in: .whitespaces).isEmpty)
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
                .textInputAutocapitalization(numeric ? .never : .words)
                #endif
        }
    }

    // MARK: - States

    private var loadingView: some View {
        HStack(spacing: AetherDesign.Spacing.s) {
            ProgressView().tint(AetherDesign.Palette.textSecondary)
            Text("Searching Jellyfin…")
                .font(AetherDesign.Typography.body)
                .foregroundStyle(AetherDesign.Palette.textSecondary)
        }
        .padding(.top, AetherDesign.Spacing.m)
    }

    private var applyingView: some View {
        HStack(spacing: AetherDesign.Spacing.s) {
            ProgressView().tint(AetherDesign.Palette.textSecondary)
            Text("Applying match on Jellyfin…")
                .font(AetherDesign.Typography.body)
                .foregroundStyle(AetherDesign.Palette.textSecondary)
        }
        .padding(.top, AetherDesign.Spacing.m)
    }

    @ViewBuilder private var resultsView: some View {
        if candidates.isEmpty {
            if didSearch {
                Text("No matches. Adjust the title or year and search again.")
                    .font(AetherDesign.Typography.caption)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
                    .padding(.top, AetherDesign.Spacing.s)
            }
        } else {
            VStack(spacing: AetherDesign.Spacing.s) {
                ForEach(candidates) { candidate in
                    candidateRow(candidate)
                }
            }
        }
    }

    private func candidateRow(_ candidate: JellyfinAPI.RemoteSearchResult) -> some View {
        Button {
            Task { await apply(candidate) }
        } label: {
            HStack(alignment: .top, spacing: AetherDesign.Spacing.m) {
                CachedAsyncImage(url: URL(string: candidate.imageURL ?? ""), aspectRatio: 2.0 / 3.0, maxPixel: ArtworkTier.thumbnail.maxPixel)
                    .frame(width: 64, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous))

                VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
                    Text(candidate.name ?? "Untitled")
                        .font(AetherDesign.Typography.body)
                        .foregroundStyle(AetherDesign.Palette.textPrimary)
                        .lineLimit(2)
                    if let meta = metaLine(candidate) {
                        Text(meta)
                            .font(AetherDesign.Typography.caption)
                            .foregroundStyle(AetherDesign.Palette.textTertiary)
                    }
                    if let overview = candidate.overview, !overview.isEmpty {
                        Text(overview)
                            .font(AetherDesign.Typography.caption)
                            .foregroundStyle(AetherDesign.Palette.textSecondary)
                            .lineLimit(3)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(AetherDesign.Typography.caption)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
            }
            .padding(AetherDesign.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AetherDesign.Materials.card, in: RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// `2021 · TheMovieDb` — year and the provider that matched.
    private func metaLine(_ c: JellyfinAPI.RemoteSearchResult) -> String? {
        var parts: [String] = []
        if let y = c.productionYear { parts.append(String(y)) }
        if let p = c.searchProviderName, !p.isEmpty { parts.append(p) }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    // MARK: - Actions

    /// Seed the query from the title (run through `TitleInference` so a raw
    /// filename like `the.film.2009.x265` becomes a clean name + year), then
    /// search immediately.
    private func start() async {
        let inferred = TitleInference(filename: currentTitle)
        name = inferred.title.isEmpty ? currentTitle : inferred.title
        yearText = (currentYear ?? inferred.year).map(String.init) ?? ""
        await search()
    }

    private func search() async {
        guard let source = session.jellyfinSource else {
            errorMessage = "Jellyfin isn't connected."
            step = .pick
            return
        }
        errorMessage = nil
        step = .loading
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let year = Int(yearText.trimmingCharacters(in: .whitespaces))
        do {
            candidates = try await source.identifyCandidates(for: itemID, kind: kind, name: query, year: year)
        } catch {
            candidates = []
            errorMessage = "Couldn't search Jellyfin. The account may not have library-management rights."
        }
        didSearch = true
        step = .pick
    }

    private func apply(_ candidate: JellyfinAPI.RemoteSearchResult) async {
        guard let source = session.jellyfinSource else { return }
        errorMessage = nil
        step = .applying
        do {
            try await source.applyIdentification(itemID, result: candidate)
            // The server is re-fetching metadata; drop the stale cached catalog
            // so Library / Detail re-read the match.
            await session.libraryDidChangeExternally(kinds: kind == .show ? [.show] : [.movie])
            onClose()
        } catch {
            errorMessage = "Couldn't apply the match. The account may not have library-management rights."
            step = .pick
        }
    }
}
