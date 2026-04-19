// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "speak-clean",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "SpeakCleanCore"),
        .executableTarget(
            name: "speak-clean",
            dependencies: ["SpeakCleanCore"]
        ),
        .testTarget(
            name: "SpeakCleanTests",
            dependencies: ["SpeakCleanCore", "speak-clean"]
        ),
    ]
)
