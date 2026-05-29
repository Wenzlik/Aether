import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import AetherCore

/// SwiftUI view that renders an arbitrary string as a QR code.
///
/// Generates a `CIImage` once when the message changes and caches the resulting
/// bitmap. Used by `PlexSignInView` so users can scan `plex.tv/link?pin=...`
/// with a phone instead of typing the URL on a tvOS keyboard.
struct QRCodeView: View {
    let message: String

    @State private var cachedImage: Image?

    var body: some View {
        Group {
            if let cachedImage {
                cachedImage
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                    .fill(AetherDesign.Palette.surface)
                    .aspectRatio(1, contentMode: .fit)
            }
        }
        .task(id: message) {
            cachedImage = Self.makeImage(for: message)
        }
    }

    private static let context = CIContext()

    private static func makeImage(for message: String) -> Image? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(message.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        // Scale up so the resulting bitmap is sharp; .interpolation(.none) in
        // the view keeps pixel edges crisp regardless of display size.
        let scale: CGFloat = 12
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }

        return Image(decorative: cgImage, scale: 1.0)
    }
}
