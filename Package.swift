// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Clawdboard",
    platforms: [.macOS(.v26)],
    targets: [
        .target(
            name: "ClawdboardLib",
            path: "Sources/ClawdboardLib",
            exclude: ["Resources"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Clawdboard",
            dependencies: ["ClawdboardLib"],
            path: "Sources/Clawdboard",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ClawdboardTests",
            dependencies: ["ClawdboardLib"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
