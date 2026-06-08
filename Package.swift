// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftResilience",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "SwiftResilience",
            targets: ["SwiftResilience"]
        ),
    ],
    targets: [
        .target(
            name: "SwiftResilience",
            path: "SwiftResilience",
            exclude: ["SwiftResilience.docc"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "SwiftResilienceTests",
            dependencies: ["SwiftResilience"],
            path: "SwiftResilienceTests"
        ),
    ]
)
