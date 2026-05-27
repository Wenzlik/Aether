import SwiftUI
import AetherCore

struct DetailView: View {
    let item: MediaItem
    @State private var isPlayerPresented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                Text(item.title)
                    .font(AetherDesign.Typography.heroTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)

                if let summary = item.summary {
                    Text(summary)
                        .font(AetherDesign.Typography.body)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                }

                Button {
                    isPlayerPresented = true
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(AetherDesign.Typography.cardTitle)
                        .padding(.horizontal, AetherDesign.Spacing.l)
                        .padding(.vertical, AetherDesign.Spacing.s)
                        .background(AetherDesign.Palette.accent.opacity(0.2),
                                    in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(item.streamURL == nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AetherDesign.Spacing.l)
        }
        .background(AetherDesign.Palette.background)
        .fullScreenCover(isPresented: $isPlayerPresented) {
            PlayerView(item: item)
        }
    }
}
