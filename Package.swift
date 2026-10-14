// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OpenEar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "OpenEar", path: "Sources/OpenEar")
    ]
)
