import SwiftUI
import AetherCore

/// Enter a personal TMDb token used for poster / metadata matching (#214).
/// A token ships with the app; this one, when set, is used **instead** — so a
/// missing or rate-limited built-in key can be fixed in-app without a rebuild.
/// Accepts a v3 API key or a v4 Read Access Token (the matcher detects which).
struct TMDbTokenEditSheet: View {
    let initialToken: String
    let hasBuiltInKey: Bool
    let onSave: (String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var isSaving = false
    @State private var loaded = false

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
                    }
                    .padding(AetherDesign.Spacing.m)
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
            AetherButton(isSaving ? "Saving…" : "Save", systemImage: "checkmark", role: .primary) {
                guard !isSaving else { return }
                Task { isSaving = true; await onSave(token); isSaving = false; dismiss() }
            }
            if !initialToken.isEmpty {
                AetherButton("Clear Custom Token", role: .destructive) {
                    Task { await onSave(""); dismiss() }
                }
            }
        }
        .padding(.top, AetherDesign.Spacing.s)
    }
}
