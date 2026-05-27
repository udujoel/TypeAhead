// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TypeAhead",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.21.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-examples", branch: "main"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "TypeAhead",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-examples"),
                .product(name: "Transformers", package: "swift-transformers"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "TypeAhead/TypeAhead",
            exclude: ["Assets.xcassets", "TypeAhead.entitlements"]
        ),
        .testTarget(
            name: "TypeAheadTests",
            dependencies: ["TypeAhead"],
            path: "Tests/TypeAheadTests"
        ),
    ]
)
