// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OpenPetsKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "OpenPetsKit", targets: ["OpenPetsKit"])
    ],
    targets: [
        .target(
            name: "OpenPetsKit",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "OpenPetsKitTests",
            dependencies: ["OpenPetsKit"]
        )
    ]
)
