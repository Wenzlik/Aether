import SwiftUI

/// A calm, on-brand loading indicator — three dots pulsing in a staggered wave
/// in the accent colour, with an optional caption. Respects Reduce Motion
/// (falls back to the system spinner). Shared across every platform's loading
/// surfaces (iOS Home, macOS Home/Discover) so they animate identically.
public struct AetherLoadingDots: View {
    public var caption: String?

    @State private var animating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let dotCount = 3
    private static let dotSize: CGFloat = 12

    public init(caption: String? = nil) {
        self.caption = caption
    }

    public var body: some View {
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
