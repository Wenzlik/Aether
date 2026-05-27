import SwiftUI
import AetherCore

struct HomeView: View {
    let source: any MediaSource

    @State private var libraries: [Library] = []
    @State private var itemsByLibrary: [Library.ID: [MediaItem]] = [:]
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                    header

                    if let loadError {
                        Text(loadError)
                            .font(AetherDesign.Typography.body)
                            .foregroundStyle(AetherDesign.Palette.textSecondary)
                            .padding(.horizontal, AetherDesign.Spacing.l)
                    }

                    ForEach(libraries) { library in
                        librarySection(library)
                    }
                }
                .padding(.vertical, AetherDesign.Spacing.l)
            }
            .background(AetherDesign.Palette.background)
            .navigationDestination(for: MediaItem.self) { item in
                DetailView(item: item)
            }
        }
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
            Text("Aether")
                .font(AetherDesign.Typography.heroTitle)
                .foregroundStyle(AetherDesign.Palette.textPrimary)
            Text("Personal media, beautifully played.")
                .font(AetherDesign.Typography.metadata)
                .foregroundStyle(AetherDesign.Palette.textSecondary)
        }
        .padding(.horizontal, AetherDesign.Spacing.l)
    }

    private func librarySection(_ library: Library) -> some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            Text(library.title)
                .font(AetherDesign.Typography.sectionTitle)
                .foregroundStyle(AetherDesign.Palette.textPrimary)
                .padding(.horizontal, AetherDesign.Spacing.l)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: AetherDesign.Spacing.m) {
                    ForEach(itemsByLibrary[library.id] ?? []) { item in
                        NavigationLink(value: item) {
                            CardView(title: item.title)
                                .frame(width: 160)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, AetherDesign.Spacing.l)
            }
        }
    }

    private func load() async {
        do {
            let libs = try await source.libraries()
            var bucket: [Library.ID: [MediaItem]] = [:]
            for lib in libs {
                bucket[lib.id] = try await source.items(in: lib.id)
            }
            libraries = libs
            itemsByLibrary = bucket
        } catch {
            loadError = "Couldn't load library: \(error.localizedDescription)"
        }
    }
}
