// swift-tools-version: 6.0
import PackageDescription

// Built in Swift 5 language mode, but with complete concurrency checking turned on so we
// stay data-race-free without forcing consumers onto the Swift 6 language mode. CI builds
// this same package in Swift 6 mode with warnings-as-errors to catch any regression.
let strictConcurrency: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency")
]

let package = Package(
    name: "Aquifer",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .visionOS(.v1),
        .watchOS(.v10),
        .tvOS(.v17),
    ],
    products: [
        .library(name: "Aquifer", targets: ["Aquifer"]),
    ],
    targets: [
        .target(
            name: "Aquifer",
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "AquiferTests",
            dependencies: ["Aquifer"],
            swiftSettings: strictConcurrency
        ),
    ],
    swiftLanguageModes: [.v5]
)
