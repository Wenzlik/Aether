import SwiftUI
import AetherCore

/// The Library tab root: pick a library, drill into its full grid.
///
/// Loads the source's libraries and presents them as large focusable tiles.
/// Selecting one pushes the existing `LibraryView` (registered as the `Library`
/// navigation destination by `mediaNavigationDestinations`). Keeps Home's job
/// (a cinematic feed) separate from Library's job (browse everything).
struct LibraryBrowseView: View {
    let source: (any MediaSource)?
    let resumeStore: ResumeStore
    let playbackSession: PlaybackSession
    let libraryPreferences: LibraryPreferencesStore
    let onAddSource: () -> Void

    @State private var libraries: [Library] = []
    @State private var isLoading = false
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            content
                .background(AetherDesign.Gradients.background.ignoresSafeArea())
                .mediaNavigationDestinations(
                    source: source,
                    resumeStore: resumeStore,
                    playbackSession: playbackSession,
                    libraryPreferences: libraryPreferences
                )
        }
        .task(id: source?.id) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if source == nil {
            AetherEmptyState(
                glyph: "rectangle.stack",
                title: "No library yet",
                message: "Connect a source to browse your movies and shows.",
                action: .init(label: "Add a source", run: onAddSource)
            )
        } else if let loadError, libraries.isEmpty {
            AetherErrorState(
                title: "Couldn't load your libraries",
                message: loadError,
                retry: .init { Task { await load() } }
            )
        } else if isLoading && libraries.isEmpty {
            AetherLoadingState(.rails(count: 1))
                .padding(.top, AetherDesign.Spacing.l)
        } else if libraries.isEmpty {
            AetherEmptyState(
                glyph: "tray",
                title: "No libraries",
                message: "This source doesn't expose any movie or show libraries Aether can read yet."
            )
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: AetherDesign.Spacing.l) {
                    ForEach(libraries) { library in
                        NavigationLink(value: library) {
                            LibraryTile(library: library)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(AetherDesign.Spacing.l)
            }
        }
    }

    private var columns: [GridItem] {
        #if os(tvOS)
        [GridItem(.adaptive(minimum: 360, maximum: 460), spacing: AetherDesign.Spacing.l)]
        #else
        [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: AetherDesign.Spacing.m)]
        #endif
    }

    private func load() async {
        loadError = nil
        guard let source else {
            libraries = []
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            libraries = try await source.libraries()
        } catch {
            libraries = []
            loadError = error.localizedDescription
        }
    }
}

/// A large, focusable library entry. No artwork (libraries have none), so it
/// leans on a kind glyph + title with Aether's standard focus lift.
private struct LibraryTile: View {
    let library: Library

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            Image(systemName: glyph)
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(AetherDesign.Palette.accent)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(library.title)
                .font(AetherDesign.Typography.cardTitle)
                .foregroundStyle(AetherDesign.Palette.textPrimary)
                .lineLimit(1)
        }
        .padding(AetherDesign.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 180)
        .background(
            AetherDesign.Palette.surface,
            in: RoundedRectangle(cornerRadius: AetherDesign.Radius.cardTV, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AetherDesign.Radius.cardTV, style: .continuous)
                .strokeBorder(AetherDesign.Palette.accent.opacity(isFocused ? 0.9 : 0.0), lineWidth: 2)
        }
        .shadow(color: AetherDesign.Palette.focusGlow.opacity(isFocused ? 0.5 : 0.0),
                radius: isFocused ? 22 : 0,
                y: isFocused ? 12 : 0)
        .scaleEffect(isFocused ? 1.04 : 1.0)
        .animation(AetherDesign.Motion.focus, value: isFocused)
    }

    private var glyph: String {
        switch library.kind {
        case .movie:  return "film.stack"
        case .show:   return "tv"
        case .season, .episode: return "rectangle.stack"
        }
    }
}
