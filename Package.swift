// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Larmindon",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
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
            path: "Tests/CoreTests"
        ),
    ]
)
