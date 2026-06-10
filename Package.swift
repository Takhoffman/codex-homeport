// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexMultihome",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "homeport", targets: ["homeport"]),
        .executable(name: "CodexMultihomeApp", targets: ["CodexMultihomeApp"]),
        .library(name: "HomeportCore", targets: ["HomeportCore"])
    ],
    targets: [
        .target(
            name: "HomeportCore"
        ),
        .executableTarget(
            name: "homeport",
            dependencies: ["HomeportCore"]
        ),
        .executableTarget(
            name: "CodexMultihomeApp",
            dependencies: ["HomeportCore"]
        ),
        .testTarget(
            name: "HomeportCoreTests",
            dependencies: ["HomeportCore"]
        )
    ]
)
