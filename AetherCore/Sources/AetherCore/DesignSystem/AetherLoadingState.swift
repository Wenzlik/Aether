import SwiftUI

/// A calm loading state — skeleton rails, no spinners.
///
/// `AetherLoadingState.rails(count:)` matches the Home page rhythm (a title row
/// + a horizontal strip of poster placeholders) and uses `.redacted` so the
/// shape mirrors real content. `AetherLoadingState.inline()` is a thin
/// horizontal pulse for footer / hint use, where a full rail would be too much.
public struct AetherLoadingState: View {
    public enum Style: Sendable {
        case rails(count: Int)
        case inline
    }

    public let style: Style
    /// Optional rotating one-liners shown above the skeleton — a playful, clearly
    /// *alive* loading cue for slow loads (e.g. an SMB share walk) so the wait
    /// reads as "still working", not a frozen placeholder. Caller-supplied so
    /// `AetherCore` stays generic; localized via the catalog. Empty ⇒ the calm
    /// skeleton-only behaviour. Rendered as `LocalizedStringKey`.
    public let captions: [String]

    @State private var captionIndex = 0

    public init(_ style: Style = .rails(count: 2), captions: [String] = []) {
        self.style = style
        self.captions = captions
    }

    public var body: some View {
        Group {
            if captions.isEmpty {
                content
            } else {
                VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                    caption
                    content
                }
                .task { await rotateCaptions() }
            }
        }
        #if os(tvOS)
        // A pushed screen stuck on a loading state has nothing focusable, so the
        // Menu button would exit the app instead of popping. Make the loading
        // state focusable on tvOS so Back works even mid-load (#311).
        .focusable()
        #endif
    }

    /// The current rotating one-liner, cross-fading as it changes.
    private var caption: some View {
        Text(LocalizedStringKey(captions[min(captionIndex, captions.count - 1)]))
            .font(AetherDesign.Typography.cardTitle)
            .foregroundStyle(AetherDesign.Palette.textSecondary)
            .padding(.horizontal, AetherDesign.Spacing.l)
            .id(captionIndex)
            .transition(.opacity)
    }

    /// Advance the caption every couple of seconds while the loader is on screen.
    /// No-op for 0/1 captions. Cancelled automatically when the view goes away.
    @MainActor
    private func rotateCaptions() async {
        guard captions.count > 1 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2.6))
            if Task.isCancelled { break }
            withAnimation(.easeInOut(duration: 0.45)) {
                captionIndex = (captionIndex + 1) % captions.count
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch style {
        case let .rails(count):
            railsBody(count: count)
        case .inline:
            inlineBody
        }
    }

    // MARK: - Rails

    private func railsBody(count: Int) -> some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            ForEach(0..<max(1, count), id: \.self) { _ in
                Rectangle()
                    .fill(AetherDesign.Palette.surface)
                    .frame(height: 22)
                    .frame(maxWidth: 220, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(.horizontal, AetherDesign.Spacing.l)

                HStack(spacing: AetherDesign.Spacing.m) {
                    ForEach(0..<4, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                            .fill(AetherDesign.Palette.surface)
                            .frame(width: cardWidth, height: cardHeight)
                    }
                }
                .padding(.horizontal, AetherDesign.Spacing.l)
            }
        }
        .redacted(reason: .placeholder)
    }

    private var cardWidth: CGFloat {
        #if os(tvOS)
        300
        #else
        160
        #endif
    }

    private var cardHeight: CGFloat {
        cardWidth * (3.0 / 2.0)
    }

    // MARK: - Inline

    private var inlineBody: some View {
        Rectangle()
            .fill(AetherDesign.Palette.surface)
            .frame(height: 14)
            .frame(maxWidth: 220, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .redacted(reason: .placeholder)
    }
}

#if DEBUG
struct AetherLoadingState_Previews: PreviewProvider {
    static var previews: some View {
        AetherLoadingState(.rails(count: 2))
            .padding(.vertical, AetherDesign.Spacing.l)
            .background(AetherDesign.Palette.background)
            .previewLayout(.sizeThatFits)
    }
}
#endif
