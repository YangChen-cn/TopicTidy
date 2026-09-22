// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TopicTidy",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TopicTidyCore", targets: ["TopicTidyCore"]),
        .executable(name: "tt", targets: ["tt"]),
        .executable(name: "TopicTidy", targets: ["TopicTidy"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: [
        // Pure native core: scanning, extraction, semantics, clustering, operations.
        .target(name: "TopicTidyCore"),
        // Native CLI sharing the same core as the GUI.
        .executableTarget(
            name: "tt",
            dependencies: [
                "TopicTidyCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // Existing SwiftUI menu bar client.
        .executableTarget(name: "TopicTidy", dependencies: ["TopicTidyCore"]),
        // Fixtures are read from disk via `#filePath`, so they stay out of the bundle.
        .testTarget(
            name: "TopicTidyCoreTests",
            dependencies: ["TopicTidyCore"],
            exclude: ["Fixtures"]
        ),
    ]
)
