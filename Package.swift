// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Larmindon",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "LarmindonKit", targets: ["LarmindonKit"]),
    ],
    targets: [
        .target(
            name: "LarmindonKit",
            path: "Sources",
            exclude: ["App"]
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["LarmindonKit"],
            path: "Tests/CoreTests",
            resources: [.process("Fixtures")]
        ),
    ]
)
