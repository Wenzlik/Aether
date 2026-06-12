import SwiftUI

/// A focusable single-choice row used by the audio and subtitle pickers on the
/// Detail screen. Leading checkmark marks the active choice; the whole row is a
/// native-focus target with Aether's standard focus lift.
///
/// Two of these (audio, subtitles) share this primitive so the lists can't
/// drift apart — see `docs/ux/DESIGN_PRINCIPLES.md` → *Track selection*.
public struct AetherSelectionRow: View {
    public let title: String
    public let detail: String?
    public let isSelected: Bool
    public let action: () -> Void

    public init(
        title: String,
        detail: String? = nil,
        isSelected: Bool,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.detail = detail
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: AetherDesign.Spacing.m) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isSelected ? AetherDesign.Palette.accent : AetherDesign.Palette.textTertiary)
                    .frame(width: 24)

                Text(LocalizedStringKey(title))
                    .font(AetherDesign.Typography.body)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: AetherDesign.Spacing.s)

                if let detail {
                    Text(LocalizedStringKey(detail))
                        .font(AetherDesign.Typography.metadata)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, AetherDesign.Spacing.m)
            .padding(.horizontal, AetherDesign.Spacing.m)
            .contentShape(Rectangle())
            .aetherFocusRow()
        }
        .buttonStyle(.plain)
    }
}

#if DEBUG
struct AetherSelectionRow_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 0) {
            AetherSelectionRow(title: "English", detail: "TrueHD · 7.1", isSelected: true) {}
            AetherSelectionRow(title: "Czech", detail: "AC3 · 5.1", isSelected: false) {}
            AetherSelectionRow(title: "Off", isSelected: false) {}
        }
        .padding(AetherDesign.Spacing.l)
        .background(AetherDesign.Palette.background)
        .previewLayout(.sizeThatFits)
    }
}
#endif
