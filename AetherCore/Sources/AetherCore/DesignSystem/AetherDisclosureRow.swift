import SwiftUI

/// A compact disclosure row: a `label` on the left, the current `value` in
/// muted text on the right, and a trailing chevron hinting at a deeper sheet
/// or modal selector behind the tap.
///
/// Lives next to `AetherSettingsRow` and `AetherSelectionRow` in the row
/// family. The settings row is for **state display** (read or status); the
/// selection row is for **one option among many** (radio-style). This row is
/// for **the chosen option, with more behind a tap** — the iOS-native
/// disclosure pattern from Settings.app and Plex Web's bottom-sheet pickers.
///
/// Tap opens whatever sheet / picker the caller wants. The row itself takes
/// no opinion on what's behind it; it just looks like the right surface to
/// reveal one.
///
/// Example:
/// ```swift
/// AetherDisclosureRow(
///     label: "Audio",
///     value: "English · EAC3 5.1"
/// ) { isAudioPickerOpen = true }
/// ```
public struct AetherDisclosureRow: View {
    public let label: String
    public let value: String?
    public let systemImage: String?
    public let action: () -> Void

    public init(
        label: String,
        value: String?,
        systemImage: String? = nil,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.value = value
        self.systemImage = systemImage
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: AetherDesign.Spacing.m) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(AetherDesign.Typography.body)
                        .foregroundStyle(AetherDesign.Palette.accent)
                        .frame(width: 28)
                }
                Text(label)
                    .font(AetherDesign.Typography.body)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)
                Spacer(minLength: AetherDesign.Spacing.s)
                if let value, !value.isEmpty {
                    Text(value)
                        .font(AetherDesign.Typography.metadata)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
            }
            .padding(.vertical, AetherDesign.Spacing.m)
            .padding(.horizontal, AetherDesign.Spacing.m)
            .contentShape(Rectangle())
            .aetherFocusRow()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(value ?? ""))
    }
}
