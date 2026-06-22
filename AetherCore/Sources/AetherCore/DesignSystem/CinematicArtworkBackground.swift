import SwiftUI

/// Full-screen, under-everything artwork background for Detail (#290).
///
/// Instead of the title's art reading as a hero *band* that ends before the
/// overview / episodes / rails (which then fall back to a flat dark surface),
/// this pins the artwork behind the **entire** page so the screen feels like
/// one continuous scene — Netflix / Infuse style. Content stays readable through
/// a vertical scrim that fades the art into the base background, never opaque
/// cards.
///
/// - Wide **backdrops** render crisp (aspect-fill) — pass `blurRadius: 0`.
/// - **Poster** fallbacks (no backdrop) are enlarged + blurred into atmosphere
///   rather than looking like a cropped, mis-sized hero — pass a blur.
/// - `fitTop: true` (compact/iPhone) pins the image at 16:9 height at the top
///   rather than aspect-filling the full screen — a 16:9 backdrop on a 9:20
///   portrait phone would otherwise crop ~75 % of the image away.
public struct CinematicArtworkBackground: View {
    public let url: URL?
    public let blurRadius: CGFloat
    public let maxPixel: CGFloat
    /// When `true` the backdrop is shown at its natural 16:9 ratio (capped at
    /// 34 % of the viewport height) anchored to the top, rather than
    /// aspect-filled to the full screen. Use on compact-width devices (iPhone)
    /// to avoid the extreme zoom that fill produces on a tall narrow screen.
    public let fitTop: Bool

    public init(
        url: URL?,
        blurRadius: CGFloat = 0,
        maxPixel: CGFloat = AetherImageCache.defaultMaxPixel,
        fitTop: Bool = false
    ) {
        self.url = url
        self.blurRadius = blurRadius
        self.maxPixel = maxPixel
        self.fitTop = fitTop
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                // Base — also the colour the artwork fades into, and the whole
                // background when a title has no art at all.
                AetherDesign.Palette.background

                if let url {
                    let h = fitTop
                        ? min(geo.size.width * 9 / 16, geo.size.height * 0.34)
                        : geo.size.height
                    CachedAsyncImage(url: url, maxPixel: maxPixel)
                        // Pin to the screen + clip so the aspect-fill image can't
                        // push layout (it's a sibling of the content in Detail's
                        // ZStack, but clipping keeps the blur from bleeding too).
                        .frame(width: geo.size.width, height: h)
                        .clipped()
                        .blur(radius: blurRadius)
                        // Readability scrim: art stays present up top (the hero
                        // region) and fades into the base background going down,
                        // so overview / episodes / rails sit on a calm surface.
                        .overlay {
                            LinearGradient(
                                colors: [
                                    AetherDesign.Palette.background.opacity(0.20),
                                    AetherDesign.Palette.background.opacity(0.55),
                                    AetherDesign.Palette.background.opacity(0.90),
                                    AetherDesign.Palette.background
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
