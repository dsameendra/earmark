// swift-tools-version: 6.3
import PackageDescription

// Qwen3-ASR (Sinhala) on MLX: the app's second ML runtime (ADR-004, specs/research/sinhala-asr.md).
//
// Kept in its own package so that MLX (Metal, tools 6.3, `unsafeFlags` in mlx-audio-swift) never leaks into the WhisperKit-only
// `Transcription` package. mlx-audio-swift is pinned by revision ff174ab (>= 01dec7c, the feature-extraction fix; 01dec7c itself does not compile under Swift 6.4 strict concurrency, ff174ab "fix warnings" does); SwiftPM requires a
// revision pin because that package uses `unsafeFlags`.
//
// Deliberately depends only on AppCore and AudioCapture: mlx-audio-swift pulls in swift-transformers, whose internal target is
// also named `Models`, which collides with this repo's `Models` package target in Xcode's package graph (xcodebuild: "multiple
// packages ('models', 'swift-transformers') declare targets with a conflicting name"). See the T25 report (SCR).
//
// `swift test` cannot load MLX's Metal library: tests that run the real model must be run with
// `xcodebuild test -scheme QwenASR -destination platform=macOS` from this directory. The pure unit tests run with both.
let package = Package(
    name: "QwenASR",
    platforms: [.macOS(.v26)],
    products: [.library(name: "QwenASR", targets: ["QwenASR"])],
    dependencies: [
        .package(path: "../AppCore"),
        .package(path: "../AudioCapture"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.33.0"),
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", revision: "ff174ab2e961aa7516dedecf273be54c24b6426d"),
    ],
    targets: [
        .target(
            name: "QwenASR",
            dependencies: [
                .product(name: "AppCore", package: "AppCore"),
                .product(name: "AudioCapture", package: "AudioCapture"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
            ],
            swiftSettings: [.treatAllWarnings(as: .error)]),
        .testTarget(
            name: "QwenASRTests",
            dependencies: [
                "QwenASR", .product(name: "AppCoreTesting", package: "AppCore"),
                .product(name: "AudioCapture", package: "AudioCapture"),
            ]),
    ],
    swiftLanguageModes: [.v6]
)
