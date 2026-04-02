// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DynamicIsland",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "DynamicIsland",
            path: "Sources/DynamicIsland"
        )
    ]
)
