// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "speak-clean",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/exPHAT/SwiftWhisper.git", branch: "master"),
    ],
    targets: [
        .target(
            name: "SpeakCleanCore",
            dependencies: ["SwiftWhisper"]
        ),
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
