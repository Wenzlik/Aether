// swift-tools-version: 6.0
import PackageDescription

// Local SPM wrapper around the OFFICIAL VideoLAN VLCKit xcframework, fetched by
// scripts/fetch_vlckit.sh (≈2.4 GB, .gitignored). VideoLAN ships VLCKit only as
// a CocoaPods .tar.xz, so we vendor their binary and expose it as an SPM product.
// Plays containers/codecs AVFoundation can't (mkv, avi, …). LGPL-2.1 — see
// Vendor/VLCKit/COPYING.txt.
let package = Package(
    name: "VLCKit",
    platforms: [.iOS(.v13), .tvOS(.v13), .visionOS(.v1), .macOS(.v10_15)],
    products: [.library(name: "VLCKit", targets: ["VLCKit"])],
    targets: [.binaryTarget(name: "VLCKit", path: "VLCKit.xcframework")]
)
