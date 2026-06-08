import SwiftUI

/// Body text that collapses to a few lines with a **More / Less** toggle when
/// it's long — so a long synopsis doesn't push the rest of the Detail screen
/// far down. Uses a length heuristic to decide whether the toggle is worth
/// showing (avoids a pointless "More" on a one-line description).
public struct AetherExpandableText: View {
    public let text: String
    public var collapsedLineLimit: Int
    /// Above this length the text is treated as long enough to collapse.
    public var collapseThreshold: Int

    public init(_ text: String, collapsedLineLimit: Int = 4, collapseThreshold: Int = 180) {
        self.text = text
        self.collapsedLineLimit = collapsedLineLimit
        self.collapseThreshold = collapseThreshold
    }

    @State private var expanded = false

    private var isLong: Bool { text.count > collapseThreshold }

    public var body: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.s) {
            Text(text)
                .font(AetherDesign.Typography.body)
                .foregroundStyle(AetherDesign.Palette.textSecondary)
                .lineLimit(expanded || !isLong ? nil : collapsedLineLimit)
                .fixedSize(horizontal: false, vertical: true)

            if isLong {
                Button(expanded ? "Less" : "More") {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                }
                .font(AetherDesign.Typography.metadata)
                .foregroundStyle(AetherDesign.Palette.accent)
                .buttonStyle(.plain)
                .accessibilityHint(expanded ? "Collapse description" : "Expand description")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
