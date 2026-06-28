import CoreGraphics
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public extension AetherPlatformImage {
    /// Whether a clearLogo is so dark it won't read over a backdrop, so the hero
    /// can fall back to the legible text title. Measures the alpha-weighted
    /// average luminance of the mark's visible pixels on a cheap 24×24 downscale.
    /// Cross-platform (UIImage / NSImage).
    func aetherLogoIsTooDark(threshold: Double = 0.42) -> Bool {
        guard let cg = aetherCGImage else { return false }
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))

        var lumSum = 0.0, alphaSum = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[i + 3]) / 255.0
            guard a > 0.05 else { continue }            // skip transparent areas
            // Un-premultiply to recover the mark's true colour.
            let r = Double(pixels[i]) / 255.0 / a
            let g = Double(pixels[i + 1]) / 255.0 / a
            let b = Double(pixels[i + 2]) / 255.0 / a
            lumSum += (0.299 * r + 0.587 * g + 0.114 * b) * a
            alphaSum += a
        }
        guard alphaSum > 0 else { return false }
        return (lumSum / alphaSum) < threshold
    }

    private var aetherCGImage: CGImage? {
        #if canImport(UIKit)
        return cgImage
        #elseif canImport(AppKit)
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #else
        return nil
        #endif
    }
}
