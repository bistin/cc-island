// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DynamicIsland",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "DynamicIsland",
            path: "Sources/DynamicIsland"
        ),
        // Tiny CLI binary that replaces hooks/island-hook.sh.
        // Foundation-only so the binary stays small and the user no longer
        // needs jq installed.
        .executableTarget(
            name: "island-hook",
            path: "Sources/island-hook"
        ),
    ]
)
