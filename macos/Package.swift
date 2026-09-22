// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "TopicTidy",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "TopicTidy", targets: ["TopicTidy"])],
    targets: [.executableTarget(name: "TopicTidy")]
)
