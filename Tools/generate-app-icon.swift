#!/usr/bin/env swift
//
// generate-app-icon.swift
//
// Renders Aether's temporary app icon to a 1024×1024 PNG using Core Graphics.
// Pure command-line — needs no Xcode, just the Swift toolchain + system
// frameworks. Run from the repo root:
//
//     swift Tools/generate-app-icon.swift
//
// Output: Aether/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png
//
// The design is deliberately simple and on-brand (calm, premium, cinematic):
// a deep diagonal indigo→black gradient with a soft, glowing rounded play
// triangle in the app's accent steel. This is a PLACEHOLDER — a real icon
// from a designer replaces it before any public release.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let scale = CGFloat(size)

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("Couldn't create CGContext")
}

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [r, g, b, a])!
}

// MARK: - Background gradient (deep indigo → near-black, diagonal)

let bgTop = color(0.10, 0.10, 0.17)     // dark indigo
let bgBottom = color(0.02, 0.02, 0.04)  // near-black
let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [bgTop, bgBottom] as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: scale),         // top-left
    end: CGPoint(x: scale, y: 0),           // bottom-right
    options: []
)

// Subtle vignette to add depth toward the corners.
let vignette = CGGradient(
    colorsSpace: colorSpace,
    colors: [color(0, 0, 0, 0), color(0, 0, 0, 0.35)] as CFArray,
    locations: [0.55, 1.0]
)!
ctx.drawRadialGradient(
    vignette,
    startCenter: CGPoint(x: scale / 2, y: scale / 2), startRadius: 0,
    endCenter: CGPoint(x: scale / 2, y: scale / 2), endRadius: scale * 0.72,
    options: []
)

// MARK: - Play triangle (rounded corners, accent-tinted, soft glow)

let accent = color(0.80, 0.80, 0.90)
let glow = color(0.62, 0.62, 0.82, 0.9)

// Optically-centred, right-pointing triangle.
let tip = CGPoint(x: scale * 0.685, y: scale * 0.5)
let topLeft = CGPoint(x: scale * 0.375, y: scale * 0.5 + scale * 0.185)
let bottomLeft = CGPoint(x: scale * 0.375, y: scale * 0.5 - scale * 0.185)
let cornerRadius = scale * 0.045

let path = CGMutablePath()
// Start mid-edge so the first arc has a clean tangent.
path.move(to: CGPoint(x: (bottomLeft.x + tip.x) / 2, y: (bottomLeft.y + tip.y) / 2))
path.addArc(tangent1End: tip, tangent2End: topLeft, radius: cornerRadius)
path.addArc(tangent1End: topLeft, tangent2End: bottomLeft, radius: cornerRadius)
path.addArc(tangent1End: bottomLeft, tangent2End: tip, radius: cornerRadius)
path.closeSubpath()

// Soft glow behind the triangle.
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: scale * 0.06, color: glow)
ctx.addPath(path)
ctx.setFillColor(accent)
ctx.fillPath()
ctx.restoreGState()

// Crisp triangle on top of the glow.
ctx.addPath(path)
ctx.setFillColor(accent)
ctx.fillPath()

// MARK: - Write PNG

guard let image = ctx.makeImage() else {
    fatalError("Couldn't render image")
}

let outputPath = "Aether/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
let url = URL(fileURLWithPath: outputPath)
guard let dest = CGImageDestinationCreateWithURL(
    url as CFURL,
    UTType.png.identifier as CFString,
    1,
    nil
) else {
    fatalError("Couldn't create image destination at \(outputPath)")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else {
    fatalError("Couldn't write PNG")
}

print("Wrote \(outputPath) (\(size)×\(size))")
