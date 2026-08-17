// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PastefixCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PastefixCore", targets: ["PastefixCore"]),
        .library(name: "PastefixAppCore", targets: ["PastefixAppCore"]),
    ],
    targets: [
        .target(name: "PastefixCore"),
        .testTarget(
            name: "PastefixCoreTests",
            dependencies: ["PastefixCore"],
            resources: [.copy("Fixtures")]
        ),
        .target(name: "PastefixAppCore", dependencies: ["PastefixCore"]),
        .testTarget(name: "PastefixAppCoreTests", dependencies: ["PastefixAppCore"]),
    ]
)
