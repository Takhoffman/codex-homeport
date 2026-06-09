// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexHomeport",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "homeport", targets: ["homeport"]),
        .executable(name: "CodexHomeportApp", targets: ["CodexHomeportApp"]),
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
            name: "CodexHomeportApp",
            dependencies: ["HomeportCore"]
        ),
        .testTarget(
            name: "HomeportCoreTests",
            dependencies: ["HomeportCore"]
        )
    ]
)
