import SwiftUI

/// Title row used above every horizontal rail on Home.
///
/// Sits alone in a row with generous space above and below; never crammed against
/// content. See `docs/ux/DESIGN_PRINCIPLES.md` → *Spacing* and *Typography*.
public struct SectionHeader: View {
    public let title: String
    public let subtitle: String?
    public let accessoryTitle: String?
    public let accessoryAction: (@MainActor () -> Void)?

    public init(
        title: String,
        subtitle: String? = nil,
        accessoryTitle: String? = nil,
        accessoryAction: (@MainActor () -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accessoryTitle = accessoryTitle
        self.accessoryAction = accessoryAction
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xxs) {
                Text(title)
                    .font(AetherDesign.Typography.sectionTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(AetherDesign.Typography.caption)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                }
            }

            Spacer()

            if let accessoryTitle, let accessoryAction {
                Button(action: accessoryAction) {
                    Text(accessoryTitle)
                        .font(AetherDesign.Typography.metadata)
                        .foregroundStyle(AetherDesign.Palette.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, AetherDesign.Spacing.l)
    }
}

#if DEBUG
struct SectionHeader_Previews: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
            SectionHeader(title: "Featured")
            SectionHeader(
                title: "Continue Watching",
                subtitle: "Picked up where you left off",
                accessoryTitle: "See all",
                accessoryAction: {}
            )
        }
        .padding(.vertical, AetherDesign.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AetherDesign.Palette.background)
        .previewLayout(.sizeThatFits)
    }
}
#endif
