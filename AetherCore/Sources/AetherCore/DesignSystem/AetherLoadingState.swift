import SwiftUI

/// A calm loading state — the on-brand `AetherLoadingDots`, never a skeleton.
///
/// Both styles render the same pulsing-dots indicator; they differ only in how
/// much vertical room they claim. `.rails(count:)` fills a page-sized area (it
/// used to mock up that many rails), `.inline` is a compact footer / hint loader.
/// The `count` is retained for source compatibility but no longer drawn.
///
/// (Was a `.redacted` skeleton; replaced app-wide so a skeleton never shows —
/// the first paint is always a clear "loading" cue instead of ghost content.)
public struct AetherLoadingState: View {
    public enum Style: Sendable {
        case rails(count: Int)
        case inline
    }

    public let style: Style
    /// Optional rotating one-liners shown under the loader — a playful, clearly
    /// *alive* cue for slow loads (e.g. an SMB share walk) so the wait reads as
    /// "still working". Caller-supplied so `AetherCore` stays generic; localized
    /// via the catalog. Empty ⇒ a captionless loader. Rendered as `LocalizedStringKey`.
    public let captions: [String]

    @State private var captionIndex = 0

    public init(_ style: Style = .rails(count: 2), captions: [String] = []) {
        self.style = style
        self.captions = captions
    }

    public var body: some View {
        AetherLoadingDots(caption: currentCaption)
            .frame(maxWidth: .infinity)
            .padding(.vertical, verticalPadding)
            .task { await rotateCaptions() }
            #if os(tvOS)
            // A pushed screen stuck on a loading state has nothing focusable, so
            // the Menu button would exit the app instead of popping. Make the
            // loading state focusable on tvOS so Back works mid-load (#311).
            .focusable()
            #endif
    }

    /// `.rails` fills a page; `.inline` is a slim footer loader.
    private var verticalPadding: CGFloat {
        switch style {
        case .rails: return AetherDesign.Spacing.xxl
        case .inline: return AetherDesign.Spacing.m
        }
    }

    /// The current rotating one-liner, or `nil` when no captions were supplied.
    private var currentCaption: String? {
        guard !captions.isEmpty else { return nil }
        return captions[min(captionIndex, captions.count - 1)]
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
