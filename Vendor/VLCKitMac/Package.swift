// swift-tools-version: 6.0
import PackageDescription

// macOS-only VLCKit, **3.x** (stable desktop build). Distinct from the unified
// VLCKit 4 in Vendor/VLCKit: the 4.x mobile build is configured `--disable-macosx`
// (no native macOS video output → its generic GL vout asserts on Apple Silicon),
// while VLCKit 3.x is the build that powers the desktop VLC and renders on macOS.
// iOS/tvOS/visionOS keep VLCKit 4 (3.x has no visionOS); only AetherMac links
// this. Fetched by scripts/fetch_vlckit_mac.sh (.gitignored). LGPL-2.1.
let package = Package(
    name: "VLCKitMac",
    platforms: [.macOS(.v10_15)],
    products: [.library(name: "VLCKitMac", targets: ["VLCKitMac"])],
    targets: [.binaryTarget(name: "VLCKitMac", path: "VLCKit.xcframework")]
)
