// swift-tools-version: 6.0
// NOTE: This package is used for unit tests only (swift test).
// The full app is built in Xcode where MLX/MLXLLM/Sparkle are added via
// File → Add Package Dependencies. The SPM target excludes files that
// require those frameworks so pure-logic tests can run without them.
import PackageDescription

let package = Package(
    name: "TypeAhead",
    platforms: [.macOS(.v14)],
    dependencies: [],
    targets: [
        .target(
            name: "TypeAhead",
            dependencies: [],
            path: "TypeAhead/TypeAhead",
            exclude: [
                "Assets.xcassets",
                "TypeAhead.entitlements",
                // Requires MLXLLM — not an SPM library product; built in Xcode only
                "Core/InferenceEngine.swift",
                // Requires swift-transformers (Hub/Tokenizers) — built in Xcode only
                "Core/HFBridge.swift",
                // Depends on InferenceEngine
                "Models/ModelManager.swift",
                // Requires Sparkle — built in Xcode only
                "App/AppDelegate.swift",
                "App/AppDependencies.swift",
                "UI/StatusBar/StatusBarMenu.swift",
                // Requires ScreenSaver framework
                "Context/ScreenshotContextProvider.swift",
                // Requires SwiftUI + AppKit combo that needs the full app bundle
                "TypeAheadApp.swift",
                "UI/Settings",
            ]
        ),
        .testTarget(
            name: "TypeAheadTests",
            dependencies: ["TypeAhead"],
            path: "Tests/TypeAheadTests",
            exclude: [
                // These test the excluded-above files or require hardware
                "OverlayPositionerTests.swift",
                "CompletionPipelineTests.swift",
            ]
        ),
    ]
)
