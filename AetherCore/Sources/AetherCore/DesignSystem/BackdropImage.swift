import SwiftUI

/// Full-bleed cinematic backdrop used on Detail screens.
///
/// Adapts to width so it's edge-to-edge on every device:
/// - `height == nil` (compact / iPhone): a full-width **16:9** image (no crop).
/// - `height` set (regular / iPad · tvOS · visionOS): **fill** the full width at
///   that fixed height, cropping — so a wide screen gets an edge-to-edge band
///   instead of a small letterboxed image with side gutters.
///
/// A soft bottom gradient fades the artwork into the page below it.
public struct BackdropImage: View {
    public let url: URL?
    public let height: CGFloat?
    /// Longest-edge downsample ceiling, paired with the server tier `url` was
    /// minted at — e.g. `ArtworkTier.backdropLarge.maxPixel` for a full-screen
    /// tvOS / visionOS hero. Defaults to the regular backdrop size.
    public let maxPixel: CGFloat

    public init(
        url: URL?,
        height: CGFloat? = nil,
        maxPixel: CGFloat = AetherImageCache.defaultMaxPixel
    ) {
        self.url = url
        self.height = height
        self.maxPixel = maxPixel
    }

    public var body: some View {
        backdrop
            .overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [
                        AetherDesign.Palette.background.opacity(0.0),
                        AetherDesign.Palette.background.opacity(0.65),
                        AetherDesign.Palette.background
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)
            }
    }

    @ViewBuilder
    private var backdrop: some View {
        if let height {
            CachedAsyncImage(url: url, maxPixel: maxPixel)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .clipped()
        } else {
            CachedAsyncImage(url: url, aspectRatio: 16.0 / 9.0, maxPixel: maxPixel)
                .frame(maxWidth: .infinity)
        }
    }
}

#if DEBUG
struct BackdropImage_Previews: PreviewProvider {
    static var previews: some View {
        BackdropImage(url: nil)
            .frame(width: 480)
            .background(AetherDesign.Palette.background)
            .previewLayout(.sizeThatFits)
    }
}
#endif
