// swift-tools-version: 6.2
import PackageDescription

// Each engine lives in its own target: both FluidAudio and SpeakerKit export
// `DiarizationResult`/`Diarizer`, so one file importing both is ambiguous.
// This mirrors the real app seam (a `DiarizationEngine` protocol, swappable backends).
let package = Package(
    name: "DiarizationSpike",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "diar-poc", targets: ["diar-poc"])],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.4",
                 traits: ["Diarizer"]),  // TTS + NemoTextProcessing traits OFF
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1"),
    ],
    targets: [
        .target(name: "DiarCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "FluidEngine",
                dependencies: ["DiarCore", .product(name: "FluidAudio", package: "FluidAudio")],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "SpeakerKitEngine",
                dependencies: ["DiarCore", .product(name: "SpeakerKit", package: "argmax-oss-swift")],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "diar-poc",
                          dependencies: ["DiarCore", "FluidEngine", "SpeakerKitEngine"],
                          swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
