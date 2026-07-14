// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexMultihome",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "codex-multihome", targets: ["CodexMultihomeCLI"]),
        .executable(name: "CodexMultihomeApp", targets: ["CodexMultihomeApp"]),
        .library(name: "HomeportCore", targets: ["HomeportCore"])
    ],
    targets: [
        .target(
            name: "HomeportCore"
        ),
        .executableTarget(
            name: "CodexMultihomeCLI",
            dependencies: ["HomeportCore"],
            path: "Sources/CodexMultihomeCLI"
        ),
        .executableTarget(
            name: "CodexMultihomeApp",
            dependencies: ["HomeportCore"],
            exclude: [
                "MitmwebPatch",
                "Resources/codex-shim/.codex-shim"
            ],
            resources: [
                .copy("Resources/codex-shim"),
                .copy("Resources/mitmproxy-runtime")
            ]
        ),
        .testTarget(
            name: "HomeportCoreTests",
            dependencies: ["HomeportCore"]
        )
    ]
)
