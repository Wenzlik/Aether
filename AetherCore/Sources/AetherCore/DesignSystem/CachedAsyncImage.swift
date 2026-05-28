import SwiftUI

/// SwiftUI image view that pulls from `AetherCore`'s image cache.
///
/// The 0.1 implementation is a thin wrapper around `AsyncImage` so views can be
/// built against the right call site. A disk-backed LRU cache and downsampling
/// land with the artwork pipeline issue in 0.2.
///
/// > Never use raw `AsyncImage` in shipping code. Go through `CachedAsyncImage`
/// > so every image goes through the same future cache + decode pipeline.
public struct CachedAsyncImage: View {
    public let url: URL?
    public let aspectRatio: CGFloat?

    public init(url: URL?, aspectRatio: CGFloat? = nil) {
        self.url = url
        self.aspectRatio = aspectRatio
    }

    public var body: some View {
        Group {
            if let url {
                AsyncImage(url: url, transaction: Transaction(animation: AetherDesign.Motion.content)) { phase in
                    switch phase {
                    case .empty:
                        skeleton
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        skeleton
                    @unknown default:
                        skeleton
                    }
                }
            } else {
                skeleton
            }
        }
        .modifier(AspectModifier(ratio: aspectRatio))
        .clipped()
    }

    private var skeleton: some View {
        AetherDesign.Palette.surface
    }
}

private struct AspectModifier: ViewModifier {
    let ratio: CGFloat?

    func body(content: Content) -> some View {
        if let ratio {
            content.aspectRatio(ratio, contentMode: .fill)
        } else {
            content
        }
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
