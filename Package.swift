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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "SeamstressCore",
            path: "Sources/SeamstressCore"
        ),
        .executableTarget(
            name: "Seamstress",
            dependencies: [
                "SeamstressCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Seamstress",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(
            name: "SeamstressCoreTests",
            dependencies: ["SeamstressCore"],
            path: "Tests/SeamstressCoreTests"
        ),
    ]
)
