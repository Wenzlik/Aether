#!/usr/bin/env swift
//
// generate-app-icon.swift
//
// Renders Aether's placeholder app icon to every platform-specific asset
// shape we need to archive:
//
//   - iOS:     `Assets.xcassets/AppIcon.appiconset/icon-1024.png` (1024×1024)
//   - visionOS: `Assets.xcassets/AppIcon.solidimagestack/`
//              Back / Middle / Front layers (1024×1024 each)
//   - tvOS:    `Assets.xcassets/AppIcon.brandassets/`
//              App Icon - App Store (1280×768, 3 layers)
//              App Icon - Home Screen (400×240, 3 layers)
//              Top Shelf Image (1920×720, single image)
//
// Pure command-line — needs no Xcode, just the Swift toolchain + system
// frameworks. Run from the repo root:
//
//     swift Tools/generate-app-icon.swift
//
// The design is deliberately simple and on-brand (calm, premium, cinematic):
// a deep diagonal indigo→black gradient with a soft, glowing rounded play
// triangle in the app's accent steel. **This is a PLACEHOLDER** — a real
// icon from a designer replaces it before any public release. It lets tvOS
// and visionOS archives succeed for internal TestFlight today.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Geometry helpers

let colorSpace = CGColorSpaceCreateDeviceRGB()

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [r, g, b, a])!
}

func makeContext(width: Int, height: Int) -> CGContext {
    guard let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Couldn't create CGContext (\(width)×\(height))")
    }
    return ctx
}

// MARK: - Background gradient (Back layer for layered platforms; full bg for iOS)

func drawBackgroundGradient(into ctx: CGContext, width: Int, height: Int) {
    let w = CGFloat(width)
    let h = CGFloat(height)

    let bgTop = color(0.10, 0.10, 0.17)     // dark indigo
    let bgBottom = color(0.02, 0.02, 0.04)  // near-black
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [bgTop, bgBottom] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: h),    // top-left
        end: CGPoint(x: w, y: 0),      // bottom-right
        options: []
    )

    // Subtle vignette to add depth toward the corners.
    let vignette = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(0, 0, 0, 0), color(0, 0, 0, 0.35)] as CFArray,
        locations: [0.55, 1.0]
    )!
    let mid = CGPoint(x: w / 2, y: h / 2)
    ctx.drawRadialGradient(
        vignette,
        startCenter: mid, startRadius: 0,
        endCenter: mid, endRadius: min(w, h) * 0.72,
        options: []
    )
}

// MARK: - Play triangle (Front layer for layered platforms; on top of bg for iOS)

func drawPlayTriangle(into ctx: CGContext, width: Int, height: Int, withGlow: Bool) {
    let w = CGFloat(width)
    let h = CGFloat(height)
    let s = min(w, h)            // triangle scales with shortest side
    let cx = w / 2
    let cy = h / 2

    let accent = color(0.80, 0.80, 0.90)
    let glow = color(0.62, 0.62, 0.82, 0.9)

    // Optically-centred, right-pointing triangle.
    let tip        = CGPoint(x: cx + s * 0.185, y: cy)
    let topLeft    = CGPoint(x: cx - s * 0.125, y: cy + s * 0.185)
    let bottomLeft = CGPoint(x: cx - s * 0.125, y: cy - s * 0.185)
    let cornerRadius = s * 0.045

    let path = CGMutablePath()
    path.move(to: CGPoint(x: (bottomLeft.x + tip.x) / 2,
                          y: (bottomLeft.y + tip.y) / 2))
    path.addArc(tangent1End: tip,        tangent2End: topLeft,    radius: cornerRadius)
    path.addArc(tangent1End: topLeft,    tangent2End: bottomLeft, radius: cornerRadius)
    path.addArc(tangent1End: bottomLeft, tangent2End: tip,        radius: cornerRadius)
    path.closeSubpath()

    if withGlow {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: s * 0.06, color: glow)
        ctx.addPath(path)
        ctx.setFillColor(accent)
        ctx.fillPath()
        ctx.restoreGState()
    }

    ctx.addPath(path)
    ctx.setFillColor(accent)
    ctx.fillPath()
}

// MARK: - File writers

func writePNG(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    let dir = url.deletingLastPathComponent().path
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        fatalError("Couldn't create image destination at \(path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        fatalError("Couldn't write PNG at \(path)")
    }
    print("Wrote \(path) (\(image.width)×\(image.height))")
}

func writeJSON(_ object: Any, to path: String) {
    let url = URL(fileURLWithPath: path)
    let dir = url.deletingLastPathComponent().path
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

    let data = try! JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys]
    )
    try! data.write(to: url)
    print("Wrote \(path)")
}

// MARK: - Renderers

let assetCatalog = "Aether/Resources/Assets.xcassets"

let standardInfo: [String: Any] = [
    "version": 1,
    "author": "xcode"
]

// MARK: iOS — 1024×1024 single image

func renderIOS() {
    let size = 1024
    let ctx = makeContext(width: size, height: size)
    drawBackgroundGradient(into: ctx, width: size, height: size)
    drawPlayTriangle(into: ctx, width: size, height: size, withGlow: true)

    guard let image = ctx.makeImage() else { fatalError("iOS render failed") }
    let out = "\(assetCatalog)/AppIcon.appiconset/icon-1024.png"
    writePNG(image, to: out)

    let contents: [String: Any] = [
        "info": standardInfo,
        "images": [
            [
                "filename": "icon-1024.png",
                "idiom": "universal",
                "platform": "ios",
                "size": "1024x1024"
            ]
        ]
    ]
    writeJSON(contents, to: "\(assetCatalog)/AppIcon.appiconset/Contents.json")
}

// MARK: visionOS — Solid Image Set, 3 layers @ 1024×1024

func renderVisionOS() {
    let size = 1024
    let root = "\(assetCatalog)/AppIcon.solidimagestack"

    // Back layer: gradient background only
    do {
        let ctx = makeContext(width: size, height: size)
        drawBackgroundGradient(into: ctx, width: size, height: size)
        guard let img = ctx.makeImage() else { fatalError("visionOS back render failed") }
        writePNG(img, to: "\(root)/Back.solidimagestacklayer/Content.imageset/Back.png")
    }

    // Middle layer: empty / transparent (Apple recommends a layer here even if subtle)
    do {
        let ctx = makeContext(width: size, height: size)
        // leave fully transparent
        guard let img = ctx.makeImage() else { fatalError("visionOS middle render failed") }
        writePNG(img, to: "\(root)/Middle.solidimagestacklayer/Content.imageset/Middle.png")
    }

    // Front layer: play triangle, no background
    do {
        let ctx = makeContext(width: size, height: size)
        drawPlayTriangle(into: ctx, width: size, height: size, withGlow: true)
        guard let img = ctx.makeImage() else { fatalError("visionOS front render failed") }
        writePNG(img, to: "\(root)/Front.solidimagestacklayer/Content.imageset/Front.png")
    }

    // Metadata
    writeJSON([
        "info": standardInfo,
        "layers": [
            ["filename": "Front.solidimagestacklayer"],
            ["filename": "Middle.solidimagestacklayer"],
            ["filename": "Back.solidimagestacklayer"]
        ]
    ] as [String: Any], to: "\(root)/Contents.json")

    for layer in ["Back", "Middle", "Front"] {
        writeJSON([
            "info": standardInfo
        ] as [String: Any], to: "\(root)/\(layer).solidimagestacklayer/Contents.json")

        writeJSON([
            "info": standardInfo,
            "images": [
                [
                    "filename": "\(layer).png",
                    "idiom": "vision",
                    "scale": "2x"
                ]
            ]
        ] as [String: Any], to: "\(root)/\(layer).solidimagestacklayer/Content.imageset/Contents.json")
    }
}

// MARK: tvOS — Brand Asset

func renderTVOS() {
    let root = "\(assetCatalog)/AppIcon.brandassets"

    // App Icon - App Store: 1280×768, 3 layers
    renderTVOSAppIconStack(
        at: "\(root)/App Icon - App Store.imagestack",
        width: 1280,
        height: 768
    )

    // App Icon - Home Screen: 400×240, 3 layers
    renderTVOSAppIconStack(
        at: "\(root)/App Icon - Home Screen.imagestack",
        width: 400,
        height: 240
    )

    // Top Shelf Image: 1920×720, single layer
    do {
        let w = 1920, h = 720
        let ctx = makeContext(width: w, height: h)
        drawBackgroundGradient(into: ctx, width: w, height: h)
        drawPlayTriangle(into: ctx, width: w, height: h, withGlow: true)
        guard let img = ctx.makeImage() else { fatalError("Top Shelf render failed") }
        writePNG(img, to: "\(root)/Top Shelf Image.imageset/Top.png")

        writeJSON([
            "info": standardInfo,
            "images": [
                [
                    "filename": "Top.png",
                    "idiom": "tv",
                    "scale": "1x"
                ]
            ]
        ] as [String: Any], to: "\(root)/Top Shelf Image.imageset/Contents.json")
    }

    // Brand asset root metadata
    writeJSON([
        "info": standardInfo,
        "assets": [
            [
                "filename": "App Icon - App Store.imagestack",
                "idiom": "tv",
                "role": "primary-app-icon",
                "size": "1280x768"
            ],
            [
                "filename": "App Icon - Home Screen.imagestack",
                "idiom": "tv",
                "role": "primary-app-icon",
                "size": "400x240"
            ],
            [
                "filename": "Top Shelf Image.imageset",
                "idiom": "tv",
                "role": "top-shelf-image",
                "size": "1920x720"
            ]
        ]
    ] as [String: Any], to: "\(root)/Contents.json")
}

func renderTVOSAppIconStack(at root: String, width: Int, height: Int) {
    // Back: gradient
    do {
        let ctx = makeContext(width: width, height: height)
        drawBackgroundGradient(into: ctx, width: width, height: height)
        guard let img = ctx.makeImage() else { fatalError("tvOS back failed at \(width)×\(height)") }
        writePNG(img, to: "\(root)/Back.imagestacklayer/Content.imageset/Back.png")
    }
    // Middle: transparent
    do {
        let ctx = makeContext(width: width, height: height)
        guard let img = ctx.makeImage() else { fatalError("tvOS middle failed at \(width)×\(height)") }
        writePNG(img, to: "\(root)/Middle.imagestacklayer/Content.imageset/Middle.png")
    }
    // Front: triangle, no bg
    do {
        let ctx = makeContext(width: width, height: height)
        drawPlayTriangle(into: ctx, width: width, height: height, withGlow: true)
        guard let img = ctx.makeImage() else { fatalError("tvOS front failed at \(width)×\(height)") }
        writePNG(img, to: "\(root)/Front.imagestacklayer/Content.imageset/Front.png")
    }

    // Stack metadata
    writeJSON([
        "info": standardInfo,
        "layers": [
            ["filename": "Front.imagestacklayer"],
            ["filename": "Middle.imagestacklayer"],
            ["filename": "Back.imagestacklayer"]
        ]
    ] as [String: Any], to: "\(root)/Contents.json")

    for layer in ["Back", "Middle", "Front"] {
        writeJSON([
            "info": standardInfo
        ] as [String: Any], to: "\(root)/\(layer).imagestacklayer/Contents.json")

        writeJSON([
            "info": standardInfo,
            "images": [
                [
                    "filename": "\(layer).png",
                    "idiom": "tv",
                    "scale": "1x"
                ]
            ]
        ] as [String: Any], to: "\(root)/\(layer).imagestacklayer/Content.imageset/Contents.json")
    }
}

// MARK: - Drive

renderIOS()
renderVisionOS()
renderTVOS()
print("All platform icons regenerated.")
