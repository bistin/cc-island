// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DynamicIsland",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "DynamicIsland",
            dependencies: ["DynamicIslandCore", "IslandHookCore"],
            path: "Sources/DynamicIsland"
        ),
        // Pure, platform-agnostic helpers extracted from the app so they
        // can be linked without AppKit and covered by XCTest.
        .target(
            name: "DynamicIslandCore",
            path: "Sources/DynamicIslandCore"
        ),
        // Pure-logic library extracted from island-hook. Foundation-only so
        // it can be linked from the tiny hook CLI and covered by XCTest.
        .target(
            name: "IslandHookCore",
            path: "Sources/IslandHookCore"
        ),
        // Tiny CLI binary that replaces hooks/island-hook.sh.
        .executableTarget(
            name: "island-hook",
            dependencies: ["IslandHookCore"],
            path: "Sources/island-hook"
        ),
        .testTarget(
            name: "DynamicIslandCoreTests",
            dependencies: ["DynamicIslandCore"],
            path: "Tests/DynamicIslandCoreTests"
        ),
        .testTarget(
            name: "IslandHookCoreTests",
            dependencies: ["IslandHookCore"],
            path: "Tests/IslandHookCoreTests"
        ),
    ]
)
