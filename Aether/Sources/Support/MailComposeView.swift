#if os(iOS) || os(visionOS)
import SwiftUI
import MessageUI

/// SwiftUI wrapper around `MFMailComposeViewController` for the Support flows.
///
/// MessageUI ships on iOS / iPadOS / visionOS but **not tvOS**, so this whole
/// file is gated — the Support section is compiled out on tvOS entirely. Even
/// where the framework exists, `canSendMail` can be `false` (no Mail account
/// configured), so callers must check `MailComposeView.canSend` first and fall
/// back to a `mailto:` link.
struct MailComposeView: UIViewControllerRepresentable {
    let recipient: String
    let subject: String
    let body: String
    /// Optional text attachment (diagnostics report). Mime type defaults to plain text.
    var attachment: (data: Data, mimeType: String, fileName: String)?
    let onFinish: () -> Void

    /// Whether the device can present the mail composer right now.
    static var canSend: Bool { MFMailComposeViewController.canSendMail() }

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients([recipient])
        controller.setSubject(subject)
        controller.setMessageBody(body, isHTML: false)
        if let attachment {
            controller.addAttachmentData(attachment.data, mimeType: attachment.mimeType, fileName: attachment.fileName)
        }
        return controller
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: (any Error)?
        ) {
            onFinish()
        }
    }
}

/// Build a `mailto:` URL — the fallback when `MailComposeView.canSend` is false
/// (no Mail account) but another mail app may still handle the scheme.
func aetherMailtoURL(recipient: String, subject: String, body: String) -> URL? {
    var components = URLComponents()
    components.scheme = "mailto"
    components.path = recipient
    components.queryItems = [
        URLQueryItem(name: "subject", value: subject),
        URLQueryItem(name: "body", value: body),
    ]
    return components.url
}
#endif
