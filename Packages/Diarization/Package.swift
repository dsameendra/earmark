// swift-tools-version: 6.2
import PackageDescription

// FluidAudio and SpeakerKit both export `Diarizer` / `DiarizationResult`, so the SpeakerKit fallback lives in its own
// target (`DiarizationSpeakerKit`) and never shares a file with FluidAudio. The main `Diarization` target has no
// SpeakerKit/WhisperKit dependency.
let package = Package(
    name: "Diarization",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "Diarization", targets: ["Diarization"]),
        .library(name: "DiarizationSpeakerKit", targets: ["DiarizationSpeakerKit"]),
    ],
    dependencies: [
        .package(path: "../AppCore"),
        .package(path: "../AudioCapture"),
        .package(path: "../ModelStore"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.4", traits: ["Diarizer"]),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1"),
    ],
    targets: [
        .target(
            name: "Diarization",
            dependencies: [
                .product(name: "AppCore", package: "AppCore"),
                .product(name: "AudioCapture", package: "AudioCapture"),
                .product(name: "ModelStore", package: "ModelStore"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            swiftSettings: [.treatAllWarnings(as: .error)]),
        .target(
            name: "DiarizationSpeakerKit",
            dependencies: [
                "Diarization",
                .product(name: "AppCore", package: "AppCore"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
            ],
            swiftSettings: [.treatAllWarnings(as: .error)]),
        .testTarget(
            name: "DiarizationTests",
            dependencies: [
                "Diarization", "DiarizationSpeakerKit",
                .product(name: "AppCoreTesting", package: "AppCore"),
                .product(name: "ModelStore", package: "ModelStore"),
            ]),
    ],
    swiftLanguageModes: [.v6]
)
