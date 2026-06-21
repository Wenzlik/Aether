#if !os(tvOS)
import SwiftUI
import AetherCore

/// Correct an SMB item's title & year (#213). SMB files carry no metadata —
/// only a filename — so a mis-named release (e.g. `the.film.2009.x265.mkv`
/// vs the real title) won't match TMDb. This sheet lets the user fix the title
/// and year; on save the correction is persisted as an override, the cached
/// walk is dropped, and the next browse re-matches TMDb with the corrected
/// title → a fresh poster / overview.
///
/// Deliberately lighter than the Local Library editor: no poster picker (SMB
/// posters always come from TMDb) and no episode fields — corrections target
/// the title/year that drive the match key.
///
/// tvOS-gated: free-form text entry, matching the Local editor's gating.
struct SMBMetadataEditSheet: View {
    let itemID: MediaID
    /// Currently displayed title / year, used to pre-fill when there's no saved
    /// override yet (so the user edits from what they see).
    let currentTitle: String
    let currentYear: Int?
    let onClose: () -> Void

    @Environment(AppSession.self) private var session

    @State private var title = ""
    @State private var yearText = ""
    @State private var hasOverride = false
    @State private var isSaving = false
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                Text("Edit Title & Year")
                    .font(AetherDesign.Typography.sectionTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)

                Text("SMB files have no metadata. Correct the title and year to match a poster on TMDb.")
                    .font(AetherDesign.Typography.caption)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)

                detailsSection
                saveRow
            }
            .padding(AetherDesign.Spacing.l)
            .frame(maxWidth: AetherSheetLayout.maxContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .aetherScreenBackground()
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
                    .padding(AetherDesign.Spacing.m)
            }
            .buttonStyle(.plain)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await load() }
    }

    private var detailsSection: some View {
        AetherSettingsSection("Details") {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
                field("Title", text: $title, prompt: "Title")
                field("Year", text: $yearText, prompt: "Year", numeric: true)
            }
            .padding(AetherDesign.Spacing.m)
        }
    }

    private func field(_ label: LocalizedStringKey, text: Binding<String>, prompt: LocalizedStringKey, numeric: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
            Text(label).textCase(.uppercase)
                .font(AetherDesign.Typography.caption)
                .foregroundStyle(AetherDesign.Palette.textTertiary)
                .tracking(0.6)
            TextField(prompt, text: text)
                .textFieldStyle(.plain)
                .font(AetherDesign.Typography.body)
                .foregroundStyle(AetherDesign.Palette.textPrimary)
                .padding(AetherDesign.Spacing.m)
                .background(AetherDesign.Materials.card, in: RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                        .strokeBorder(AetherDesign.Palette.separator, lineWidth: 1)
                }
                #if os(iOS)
                .keyboardType(numeric ? .numberPad : .default)
                #endif
        }
    }

    private var saveRow: some View {
        VStack(spacing: AetherDesign.Spacing.s) {
            AetherButton(isSaving ? "Saving…" : "Save & Re-match", systemImage: "checkmark", role: .primary) {
                guard !isSaving else { return }
                Task { await save() }
            }
            if hasOverride {
                AetherButton("Reset to Detected", role: .destructive) {
                    Task { await reset() }
                }
            }
        }
        .padding(.top, AetherDesign.Spacing.s)
    }

    private func load() async {
        guard !loaded else { return }
        loaded = true
        if let override = await session.smbOverride(for: itemID) {
            hasOverride = true
            title = override.title ?? currentTitle
            yearText = override.year.map(String.init) ?? currentYear.map(String.init) ?? ""
        } else {
            title = currentTitle
            yearText = currentYear.map(String.init) ?? ""
        }
    }

    private func save() async {
        isSaving = true
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let year = Int(yearText.trimmingCharacters(in: .whitespaces))
        let override = SMBMetadataStore.Override(
            title: trimmedTitle.isEmpty ? nil : trimmedTitle,
            year: year
        )
        await session.saveSMBOverride(override.isEmpty ? nil : override, for: itemID)
        isSaving = false
        onClose()
    }

    private func reset() async {
        await session.saveSMBOverride(nil, for: itemID)
        onClose()
    }
}
#endif
