// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeFolderLauncher",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ClaudeFolderLauncher",
            path: "Sources/ClaudeFolderLauncher"
        )
    ]
)
