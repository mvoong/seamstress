// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Seamstress",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "SeamstressCore", targets: ["SeamstressCore"]),
        .executable(name: "Seamstress", targets: ["Seamstress"]),
    ],
    targets: [
        .target(
            name: "SeamstressCore",
            path: "Sources/SeamstressCore"
        ),
        .executableTarget(
            name: "Seamstress",
            dependencies: ["SeamstressCore"],
            path: "Sources/Seamstress"
        ),
        .testTarget(
            name: "SeamstressCoreTests",
            dependencies: ["SeamstressCore"],
            path: "Tests/SeamstressCoreTests"
        ),
    ]
)
