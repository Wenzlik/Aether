// swift-tools-version:6.0
import PackageDescription

// Reality Composer Pro content for Aether Cinema. Holds the per-screen-size
// immersive environments (each with a `DockingRegion` sizing the docked video
// and a reflective floor), authored in Reality Composer Pro into
// `RealityKitContent.rkassets` and loaded at runtime via `Entity(named:in:)`.
//
// RealityKit is not available on tvOS, so this package omits tvOS and is wired
// into the app as a **visionOS-only** dependency (see project.yml).
let package = Package(
    name: "RealityKitContent",
    platforms: [
        .visionOS(.v2),
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(name: "RealityKitContent", targets: ["RealityKitContent"])
    ],
    targets: [
        .target(name: "RealityKitContent")
    ]
)
