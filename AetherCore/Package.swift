// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AetherCore",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v26),
        .tvOS(.v26),
        .visionOS(.v26),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "AetherCore",
            targets: ["AetherCore"]
        )
    ],
    targets: [
        .target(
            name: "AetherCore",
            path: "Sources/AetherCore",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        // Dev-only CLI (#476): remux a real `.mkv` to fMP4 and write it out so
        // the output can be validated with ffprobe / AVFoundation off-device.
        // Not part of the app — the iOS target depends on the library product
        // only, so this never ships. Run: `swift run RemuxValidate in.mkv out.mp4`.
        .executableTarget(
            name: "RemuxValidate",
            dependencies: ["AetherCore"],
            path: "Sources/RemuxValidate"
        )
    ],
    swiftLanguageModes: [.v6]
)
