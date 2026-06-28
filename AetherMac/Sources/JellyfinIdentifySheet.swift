import SwiftUI
import AetherCore

/// Identify a mis/unidentified **Jellyfin** title from the Mac app: searches the
/// server's metadata providers (`RemoteSearch`), shows candidates, and on
/// selection applies the match server-side (`Apply`) so every client sees it.
/// Mirrors `LocalFixMatchSheet` but talks to Jellyfin instead of TMDb.
struct JellyfinIdentifySheet: View {
    let item: MediaItem
    let session: MacSession
    /// Called after a match is applied — the detail view can refresh in place.
    let onApplied: () -> Void

    @State private var query: String
    @State private var yearText: String
    @State private var candidates: [JellyfinAPI.RemoteSearchResult] = []
    @State private var isSearching = false
    @State private var isApplying = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(item: MediaItem, session: MacSession, onApplied: @escaping () -> Void) {
        self.item = item
        self.session = session
        self.onApplied = onApplied
        let inferred = TitleInference(filename: item.title)
        _query = State(initialValue: inferred.title.isEmpty ? item.title : inferred.title)
        _yearText = State(initialValue: (item.year ?? inferred.year).map(String.init) ?? "")
    }

    private var kind: MediaItem.Kind { item.kind == .show ? .show : .movie }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Identify on Jellyfin").font(.title2.bold())
                    Text(item.title).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            HStack(spacing: 8) {
                TextField("Title", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { search() }
                TextField("Year", text: $yearText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .onSubmit { search() }
                Button("Search", action: search)
                    .buttonStyle(.borderedProminent)
                    .disabled(isSearching || query.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal).padding(.vertical, 10)

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout).foregroundStyle(.orange)
                    .padding(.horizontal).padding(.bottom, 8)
            }

            Divider()

            Group {
                if isSearching {
                    ProgressView("Searching Jellyfin…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isApplying {
                    ProgressView("Applying match…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if candidates.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.quaternary)
                        Text("No matches — try adjusting the title or year").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 110, maximum: 130), spacing: 12)],
                            spacing: 16
                        ) {
                            ForEach(candidates) { candidate in
                                candidateCard(candidate)
                            }
                        }
                        .padding()
                    }
                }
            }
        }
        .frame(width: 540, height: 460)
        .task { search() }
    }

    private func candidateCard(_ candidate: JellyfinAPI.RemoteSearchResult) -> some View {
        Button {
            apply(candidate)
        } label: {
            VStack(alignment: .center, spacing: 6) {
                CachedAsyncImage(url: URL(string: candidate.imageURL ?? ""), aspectRatio: 2.0 / 3.0)
                    .frame(width: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.quaternary))
                Text(candidate.name ?? "Untitled")
                    .font(.callout.weight(.medium))
                    .lineLimit(2).multilineTextAlignment(.center)
                    .frame(width: 110)
                if let year = candidate.productionYear {
                    Text(String(year)).font(.caption).foregroundStyle(.secondary)
                }
                if let provider = candidate.searchProviderName, !provider.isEmpty {
                    Text(provider).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func search() {
        let title = query.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, let source = session.jellyfinSource(for: item.id) else { return }
        let year = Int(yearText.trimmingCharacters(in: .whitespaces))
        isSearching = true
        errorMessage = nil
        candidates = []
        Task {
            do {
                candidates = try await source.identifyCandidates(for: item.id, kind: kind, name: title, year: year)
            } catch {
                errorMessage = "Couldn't search Jellyfin. The account may not have library-management rights."
            }
            isSearching = false
        }
    }

    private func apply(_ candidate: JellyfinAPI.RemoteSearchResult) {
        guard let source = session.jellyfinSource(for: item.id) else { return }
        isApplying = true
        errorMessage = nil
        Task {
            do {
                try await source.applyIdentification(item.id, result: candidate)
                await session.libraryDidChangeExternally()
                onApplied()
                dismiss()
            } catch {
                errorMessage = "Couldn't apply the match. The account may not have library-management rights."
                isApplying = false
            }
        }
    }
}
