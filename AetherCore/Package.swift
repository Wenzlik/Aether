// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AetherCore",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v26),
        .tvOS(.v26),
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
        )
    ],
    swiftLanguageModes: [.v6]
)
