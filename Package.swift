// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GPUWatcher",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "GPUWatcher", path: "Sources/GPUWatcher")
    ]
)
