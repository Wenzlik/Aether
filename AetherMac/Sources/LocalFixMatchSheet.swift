import SwiftUI
import AetherCore

/// A sheet for manually correcting the TMDb match for a local library item.
/// Searches TMDb by title + optional year, shows poster candidates, and on
/// selection updates the item metadata (title, year, poster, backdrop, rating)
/// both in memory and in persisted UserDefaults overrides.
struct LocalFixMatchSheet: View {
    let item: MediaItem
    let session: MacSession
    /// Called when the user picks a match — the detail view can refresh in-place
    /// without waiting for a full library rescan.
    let onMatch: (TMDbMetadata) -> Void

    @State private var query: String
    @State private var yearText: String
    @State private var candidates: [TMDbMetadata] = []
    @State private var isSearching = false
    @Environment(\.dismiss) private var dismiss

    init(item: MediaItem, session: MacSession, onMatch: @escaping (TMDbMetadata) -> Void) {
        self.item = item
        self.session = session
        self.onMatch = onMatch
        _query = State(initialValue: item.title)
        _yearText = State(initialValue: item.year.map(String.init) ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fix Match")
                        .font(.title2.bold())
                    Text(item.title)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
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

            Divider()

            Group {
                if isSearching {
                    ProgressView("Searching TMDb…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if candidates.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.largeTitle)
                            .foregroundStyle(.quaternary)
                        Text("No results — try adjusting the title or year")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 110, maximum: 130), spacing: 12)],
                            spacing: 16
                        ) {
                            ForEach(candidates, id: \.tmdbID) { meta in
                                candidateCard(meta)
                            }
                        }
                        .padding()
                    }
                }
            }
        }
        .frame(width: 540, height: 440)
        .task { search() }
    }

    private func candidateCard(_ meta: TMDbMetadata) -> some View {
        Button {
            Task {
                await session.applyLocalTMDbMatch(meta, to: item)
                onMatch(meta)
            }
            dismiss()
        } label: {
            VStack(alignment: .center, spacing: 6) {
                CachedAsyncImage(url: meta.posterURL, aspectRatio: 2.0 / 3.0)
                    .frame(width: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.quaternary))
                Text(meta.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 110)
                if let year = meta.year {
                    Text(String(year))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let rating = meta.rating, rating > 0 {
                    Label(String(format: "%.1f", rating), systemImage: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func search() {
        let title = query.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        let year = Int(yearText.trimmingCharacters(in: .whitespaces))
        isSearching = true
        candidates = []
        Task {
            candidates = await session.searchTMDb(
                title: title,
                year: year,
                isEpisode: item.kind == .show
            )
            isSearching = false
        }
    }
}
