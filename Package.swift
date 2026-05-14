// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "wake",
    platforms: [.macOS(.v11)],
    targets: [
        .executableTarget(
            name: "wake",
            path: "Sources/wake"
        )
    ]
)
