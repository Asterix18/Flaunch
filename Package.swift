// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Flaunch",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Flaunch",
            path: "Sources/Flaunch"
        )
    ]
)
