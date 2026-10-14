// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OpenEar",
    platforms: [.macOS(.v14)],
    targets: [
        // Real-time audio code lives in C so the audio thread never touches the Swift runtime.
        .target(
            name: "AudioCore",
            path: "Sources/AudioCore",
            linkerSettings: [.linkedFramework("AudioToolbox")]
        ),
        .executableTarget(
            name: "OpenEar",
            dependencies: ["AudioCore"],
            path: "Sources/OpenEar"
        ),
    ]
)
