#if !os(tvOS)
import SwiftUI
import AetherCore

/// Bug-report category — drives the email subject + a "Category:" line in the body.
enum BugCategory: String, CaseIterable, Identifiable {
    case playback, library, ui, downloads, cinema, other
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .playback:  return "Playback"
        case .library:   return "Library"
        case .ui:        return "UI"
        case .downloads: return "Downloads"
        case .cinema:    return "Cinema"
        case .other:     return "Other"
        }
    }
}

// MARK: - Report a Bug

/// Lightweight in-app bug report: Subject, Description, Category → opens the Mail
/// composer to `aether@zmrhal.cz` (falls back to a `mailto:` link when no mail
/// account is configured), auto-appending the token-free diagnostics footer.
struct ReportBugSheet: View {
    let theme: String
    let onClose: () -> Void

    @State private var subject = ""
    @State private var detail = ""
    @State private var category: BugCategory = .playback
    @State private var showingMail = false
    @Environment(\.openURL) private var openURL

    private var emailSubject: String {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Aether Bug: " + (trimmed.isEmpty ? category.displayName : trimmed)
    }

    private var emailBody: String {
        """
        \(detail)


        Category: \(category.displayName)
        \(SupportDiagnostics.bugReportFooter(theme: theme))
        """
    }

    private var canSubmit: Bool {
        !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        SupportFormScaffold(
            title: "Report a Bug",
            subtitle: "Tell us what went wrong. Your app version and device are attached automatically — no account details are included.",
            submitTitle: "Continue to Mail",
            canSubmit: canSubmit,
            onSubmit: submit,
            onClose: onClose
        ) {
            SupportField(label: "Subject", text: $subject, prompt: "Short summary (optional)")
            SupportField(label: "Description", text: $detail, prompt: "What happened? Steps to reproduce?", multiline: true)
            SupportPickerField(label: "Category") {
                Picker("Category", selection: $category) {
                    ForEach(BugCategory.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.menu)
                .tint(AetherDesign.Palette.accent)
            }
        }
        .sheet(isPresented: $showingMail) {
            MailComposeView(
                recipient: SupportDiagnostics.supportEmail,
                subject: emailSubject,
                body: emailBody,
                attachment: nil
            ) { showingMail = false; onClose() }
            .ignoresSafeArea()
        }
    }

    private func submit() {
        if MailComposeView.canSend {
            showingMail = true
        } else if let url = aetherMailtoURL(recipient: SupportDiagnostics.supportEmail, subject: emailSubject, body: emailBody) {
            openURL(url)
            onClose()
        }
    }
}

// MARK: - Feature Request

/// Feature request: Title, Description → Mail composer with subject
/// "Feature Request: <title>". Attaches a light app/platform/device footer.
struct FeatureRequestSheet: View {
    let onClose: () -> Void

    @State private var title = ""
    @State private var detail = ""
    @State private var showingMail = false
    @Environment(\.openURL) private var openURL

    private var emailSubject: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Feature Request: " + (trimmed.isEmpty ? "(untitled)" : trimmed)
    }

    private var emailBody: String {
        """
        \(detail)

        \(SupportDiagnostics.featureRequestFooter())
        """
    }

    private var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        SupportFormScaffold(
            title: "Feature Request",
            subtitle: "Have an idea for Aether? We'd love to hear it.",
            submitTitle: "Continue to Mail",
            canSubmit: canSubmit,
            onSubmit: submit,
            onClose: onClose
        ) {
            SupportField(label: "Title", text: $title, prompt: "A short name for the idea")
            SupportField(label: "Description", text: $detail, prompt: "Describe what you'd like and why", multiline: true)
        }
        .sheet(isPresented: $showingMail) {
            MailComposeView(
                recipient: SupportDiagnostics.supportEmail,
                subject: emailSubject,
                body: emailBody,
                attachment: nil
            ) { showingMail = false; onClose() }
            .ignoresSafeArea()
        }
    }

    private func submit() {
        if MailComposeView.canSend {
            showingMail = true
        } else if let url = aetherMailtoURL(recipient: SupportDiagnostics.supportEmail, subject: emailSubject, body: emailBody) {
            openURL(url)
            onClose()
        }
    }
}

// MARK: - Send Diagnostics

/// Generates the readable, token-free diagnostics report, lets the user preview
/// it, then emails it (report in the body + attached as `aether-diagnostics.txt`).
struct SendDiagnosticsSheet: View {
    let gather: () async -> DiagnosticsSnapshot
    let onClose: () -> Void

    @State private var report: String?
    @State private var showingMail = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
                    Text("Send Diagnostics")
                        .font(AetherDesign.Typography.sectionTitle)
                        .foregroundStyle(AetherDesign.Palette.textPrimary)
                    Text("Review the report below, then send it to the developer. No tokens, passwords, or account details are included.")
                        .font(AetherDesign.Typography.metadata)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                }

                if let report {
                    Text(report)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(AetherDesign.Spacing.m)
                        .background(AetherDesign.Materials.card, in: RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                                .strokeBorder(AetherDesign.Palette.separator, lineWidth: 1)
                        }
                    AetherButton("Send via Mail", systemImage: "envelope.fill", role: .primary) {
                        send(report)
                    }
                } else {
                    ProgressView()
                        .tint(AetherDesign.Palette.accent)
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            .padding(AetherDesign.Spacing.l)
            .frame(maxWidth: 640, alignment: .leading)
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
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task {
            if report == nil { report = await gather().report() }
        }
        .sheet(isPresented: $showingMail) {
            MailComposeView(
                recipient: SupportDiagnostics.supportEmail,
                subject: "Aether Diagnostics",
                body: "Diagnostics report attached.\n\n\(report ?? "")",
                attachment: (
                    data: Data((report ?? "").utf8),
                    mimeType: "text/plain",
                    fileName: "aether-diagnostics.txt"
                )
            ) { showingMail = false; onClose() }
            .ignoresSafeArea()
        }
    }

    private func send(_ report: String) {
        if MailComposeView.canSend {
            showingMail = true
        } else if let url = aetherMailtoURL(
            recipient: SupportDiagnostics.supportEmail,
            subject: "Aether Diagnostics",
            body: report
        ) {
            openURL(url)
            onClose()
        }
    }
}

// MARK: - Shared form scaffolding

/// A consistent sheet shell for the Support forms — title, subtitle, the form
/// fields, and a primary submit + Cancel, over the app's cinematic background.
private struct SupportFormScaffold<Content: View>: View {
    let title: String
    let subtitle: String
    let submitTitle: String
    let canSubmit: Bool
    let onSubmit: () -> Void
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.l) {
                VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
                    Text(title).font(AetherDesign.Typography.sectionTitle)
                        .foregroundStyle(AetherDesign.Palette.textPrimary)
                    Text(subtitle).font(AetherDesign.Typography.metadata)
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                }
                content()
                AetherButton(submitTitle, systemImage: "envelope.fill", role: .primary, action: onSubmit)
                    .disabled(!canSubmit)
                    .opacity(canSubmit ? 1 : 0.5)
            }
            .padding(AetherDesign.Spacing.l)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .aetherScreenBackground()
        .overlay(alignment: .topTrailing) {
            Button { onClose() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
                    .padding(AetherDesign.Spacing.m)
            }
            .buttonStyle(.plain)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

/// A labelled text input styled to match the Settings cards.
private struct SupportField: View {
    let label: String
    @Binding var text: String
    let prompt: String
    var multiline: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
            Text(label.uppercased())
                .font(AetherDesign.Typography.caption)
                .foregroundStyle(AetherDesign.Palette.textTertiary)
                .tracking(0.6)
            Group {
                if multiline {
                    TextField(prompt, text: $text, axis: .vertical)
                        .lineLimit(4...10)
                } else {
                    TextField(prompt, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(AetherDesign.Typography.body)
            .foregroundStyle(AetherDesign.Palette.textPrimary)
            .padding(AetherDesign.Spacing.m)
            .background(AetherDesign.Materials.card, in: RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                    .strokeBorder(AetherDesign.Palette.separator, lineWidth: 1)
            }
        }
    }
}

/// A labelled container for an inline control (e.g. the category Picker).
private struct SupportPickerField<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
            Text(label.uppercased())
                .font(AetherDesign.Typography.caption)
                .foregroundStyle(AetherDesign.Palette.textTertiary)
                .tracking(0.6)
            HStack {
                content()
                Spacer(minLength: 0)
            }
            .padding(AetherDesign.Spacing.m)
            .background(AetherDesign.Materials.card, in: RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                    .strokeBorder(AetherDesign.Palette.separator, lineWidth: 1)
            }
        }
    }
}
#endif
