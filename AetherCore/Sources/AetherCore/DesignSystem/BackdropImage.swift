import SwiftUI

/// Full-bleed cinematic backdrop used on Detail screens.
///
/// Loads via `CachedAsyncImage`, applies a 16:9 frame, and adds a soft bottom
/// gradient so type laid over the lower portion stays legible regardless of
/// what the artwork is doing.
public struct BackdropImage: View {
    public let url: URL?

    public init(url: URL?) {
        self.url = url
    }

    public var body: some View {
        CachedAsyncImage(url: url, aspectRatio: 16.0 / 9.0)
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
                .frame(maxHeight: .infinity)
                .frame(height: nil)
                .allowsHitTesting(false)
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
