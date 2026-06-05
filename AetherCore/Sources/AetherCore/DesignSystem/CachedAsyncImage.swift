import SwiftUI

/// SwiftUI image view backed by `AetherImageCache` (memory + disk + downsample
/// + in-flight de-dup). Replaces the previous raw-`AsyncImage` implementation,
/// which had no persistent cache, decoded full-size, and re-fetched on every
/// render and relaunch — the artwork performance regression.
///
/// > Never use raw `AsyncImage` in shipping code. Go through `CachedAsyncImage`
/// > so every image shares the same cache + decode pipeline.
///
/// ## Sizing
///
/// When `aspectRatio` is provided, the view shapes itself to that ratio using
/// the canonical `Color.clear → overlay → clipped` pattern: the container
/// reaches the ratio first; the image is drawn into it with `.scaledToFill`
/// and clipped. Without this, the success image takes its natural ratio and the
/// card can grow past the parent's `.frame(width:)`.
public struct CachedAsyncImage: View {
    public let url: URL?
    public let aspectRatio: CGFloat?

    @State private var image: AetherPlatformImage?
    @State private var isAnimating = false

    public init(url: URL?, aspectRatio: CGFloat? = nil) {
        self.url = url
        self.aspectRatio = aspectRatio
    }

    public var body: some View {
        Group {
            if let aspectRatio {
                Color.clear
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .overlay { imageContent }
                    .clipped()
            } else {
                imageContent
            }
        }
        // Keyed on the url: reloads only when the url changes. A repeat
        // appearance of the same url is an instant memory-cache hit.
        .task(id: url) {
            guard let url else { image = nil; return }
            image = await AetherImageCache.shared.image(for: url)
        }
    }

    @ViewBuilder
    private var imageContent: some View {
        if let image {
            Image(aetherImage: image)
                .resizable()
                .scaledToFill()
        } else {
            skeleton
        }
    }

    private var skeleton: some View {
        ZStack {
            LinearGradient(
                colors: [
                    AetherDesign.Palette.surfaceElevated,
                    AetherDesign.Palette.surface
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Image(systemName: "play.rectangle")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(AetherDesign.Palette.accent.opacity(0.65))
        }
        .opacity(isAnimating ? 0.35 : 0.75)
        .onAppear {
            withAnimation(
                .easeInOut(duration: 1.2)
                .repeatForever(autoreverses: true)
            ) {
                isAnimating = true
            }
        }
    }
}

extension Image {
    /// Cross-platform `Image(uiImage:)` / `Image(nsImage:)` from a cached
    /// platform image.
    init(aetherImage: AetherPlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: aetherImage)
        #else
        self.init(nsImage: aetherImage)
        #endif
    }
}

#if DEBUG
struct CachedAsyncImage_Previews: PreviewProvider {
    static var previews: some View {
        CachedAsyncImage(url: nil, aspectRatio: 2.0 / 3.0)
            .frame(width: 160)
            .clipShape(RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous))
            .padding(AetherDesign.Spacing.l)
            .background(AetherDesign.Palette.background)
            .previewLayout(.sizeThatFits)
    }
}
#endif
