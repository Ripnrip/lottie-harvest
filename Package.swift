// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LottieHarvest",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "LottieHarvestCore", targets: ["LottieHarvestCore"]),
        .executable(name: "lottie-harvest", targets: ["lottie-harvest"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "LottieHarvestCore",
            dependencies: []
        ),
        .executableTarget(
            name: "lottie-harvest",
            dependencies: [
                "LottieHarvestCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "LottieHarvestCoreTests",
            dependencies: ["LottieHarvestCore"],
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
