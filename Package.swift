// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PastefixCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PastefixCore", targets: ["PastefixCore"])
    ],
    targets: [
        .target(name: "PastefixCore"),
        .testTarget(
            name: "PastefixCoreTests",
            dependencies: ["PastefixCore"],
            resources: [.copy("Fixtures")]
        )
    ]
)
