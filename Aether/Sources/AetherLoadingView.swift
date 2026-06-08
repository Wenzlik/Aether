import SwiftUI
import AetherCore

/// A calm, on-brand loading indicator — three dots pulsing in a staggered wave
/// in the accent colour, with an optional caption. Replaces the earlier video
/// loader. Respects Reduce Motion (falls back to the system spinner).
struct AetherLoadingDots: View {
    var caption: String?

    @State private var animating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let dotCount = 3
    private static let dotSize: CGFloat = 12

    var body: some View {
        VStack(spacing: AetherDesign.Spacing.l) {
            if reduceMotion {
                ProgressView()
                    .tint(AetherDesign.Palette.accent)
            } else {
                HStack(spacing: AetherDesign.Spacing.s) {
                    ForEach(0..<Self.dotCount, id: \.self) { index in
                        Circle()
                            .fill(AetherDesign.Palette.accent)
                            .frame(width: Self.dotSize, height: Self.dotSize)
                            .scaleEffect(animating ? 1.0 : 0.5)
                            .opacity(animating ? 1.0 : 0.35)
                            .animation(
                                .easeInOut(duration: 0.6)
                                    .repeatForever(autoreverses: true)
                                    .delay(Double(index) * 0.18),
                                value: animating
                            )
                    }
                }
                .onAppear { animating = true }
            }

            if let caption {
                Text(caption)
                    .font(AetherDesign.Typography.metadata)
                    .foregroundStyle(AetherDesign.Palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(caption ?? "Loading"))
    }
}

/// Wraps a state view (loading / empty / error) so it (1) fills the screen and
/// centers, and (2) lives inside a bouncing `ScrollView` — so the screen's
/// `.refreshable` works even when there's no content yet. Without this the
/// states render content-sized (the gradient shows as a band) and aren't
/// scrollable (pull-to-refresh can't reach them, so an empty state gets stuck).
struct AetherCenteredScrollState<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                content()
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .center)
            }
            #if !os(tvOS)
            // Always bounce so pull-to-refresh fires even when the content fits.
            .scrollBounceBehavior(.always)
            #endif
        }
    }
}
