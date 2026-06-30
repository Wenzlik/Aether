import SwiftUI
import AetherCore

/// Enter a personal TMDb token used for poster / metadata matching (#214).
/// A token ships with the app; this one, when set, is used **instead** — so a
/// missing or rate-limited built-in key can be fixed in-app without a rebuild.
/// Accepts a v3 API key or a v4 Read Access Token (the matcher detects which).
struct TMDbTokenEditSheet: View {
    let initialToken: String
    let hasBuiltInKey: Bool
    let validate: (String) async -> TMDbClient.ValidationResult
    let onSave: (String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var isSaving = false
    @State private var loaded = false
    /// Validation feedback for the last Save attempt.
    @State private var validationMessage: String?
    @State private var allowSaveAnyway = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                Text("TMDb Token")
                    .font(AetherDesign.Typography.sectionTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)

                Text(explainer)
                    .font(AetherDesign.Typography.caption)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                AetherSettingsSection("Token") {
                    VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
                        TextField("v3 API key or v4 token", text: $token)
                            .textFieldStyle(.plain)
                            .font(AetherDesign.Typography.body)
                            .foregroundStyle(AetherDesign.Palette.textPrimary)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .padding(AetherDesign.Spacing.m)
                            .background(AetherDesign.Materials.card, in: RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                                    .strokeBorder(AetherDesign.Palette.separator, lineWidth: 1)
                            }
                            // A fresh edit invalidates the last check.
                            .onChange(of: token) { _, _ in validationMessage = nil; allowSaveAnyway = false }
                    }
                    .padding(AetherDesign.Spacing.m)
                }

                if let validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(AetherDesign.Typography.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                saveRow
            }
            .padding(AetherDesign.Spacing.l)
            .frame(maxWidth: AetherSheetLayout.maxContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .aetherScreenBackground()
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
                    .padding(AetherDesign.Spacing.m)
                    // Bigger tap target: `.plain` button hit-tests only the glyph
                    // without this — the X looked tiny / hard to hit (≥44pt HIG).
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            guard !loaded else { return }
            loaded = true
            token = initialToken
        }
    }

    private var explainer: String {
        let lead = hasBuiltInKey
            ? "Aether matches posters and details from TMDb using a built-in key. Enter your own token here to use it instead — handy if matching stops working."
            : "Aether matches posters and details from TMDb. No key shipped with this build, so add your own to enable poster matching."
        return lead + "\n\nGet a free key at themoviedb.org → Settings → API (the v3 API Key or the v4 Read Access Token both work)."
    }

    private var saveRow: some View {
        VStack(spacing: AetherDesign.Spacing.s) {
            AetherButton(saveLabel, systemImage: "checkmark", role: .primary) {
                guard !isSaving else { return }
                Task { await attemptSave() }
            }
            .disabled(isSaving)
            if !initialToken.isEmpty {
                AetherButton("Clear Custom Token", role: .destructive) {
                    Task { await onSave(""); dismiss() }
                }
            }
        }
        .padding(.top, AetherDesign.Spacing.s)
    }

    private var saveLabel: String {
        if isSaving { return "Checking…" }
        return allowSaveAnyway ? "Save Anyway" : "Save"
    }

    /// Validate against TMDb, then save. A blank token clears (no check needed).
    /// A rejected token blocks the save; an unreachable TMDb offers "Save Anyway"
    /// (the key may still be fine — it just couldn't be checked right now).
    private func attemptSave() async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { await onSave(""); dismiss(); return }
        if allowSaveAnyway { await onSave(trimmed); dismiss(); return }

        isSaving = true
        defer { isSaving = false }
        switch await validate(trimmed) {
        case .valid:
            await onSave(trimmed)
            dismiss()
        case .invalid:
            validationMessage = "TMDb rejected this token. Check you copied the full v3 API key or v4 Read Access Token."
            allowSaveAnyway = false
        case .networkError:
            validationMessage = "Couldn't reach TMDb to check the token. Tap Save Anyway to keep it, or try again."
            allowSaveAnyway = true
        case .empty:
            await onSave("")
            dismiss()
        }
    }
}
