// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OpenEar",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        // Real-time audio code lives in C so the audio thread never touches the Swift runtime.
        .target(
            name: "AudioCore",
            path: "Sources/AudioCore",
            linkerSettings: [.linkedFramework("AudioToolbox")]
        ),
        .executableTarget(
            name: "OpenEar",
            dependencies: ["AudioCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/OpenEar",
            // Sparkle.framework ships inside the app at Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
    ]
)
