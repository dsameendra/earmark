// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Transcription",
    platforms: [.macOS(.v26)],
    products: [.library(name: "Transcription", targets: ["Transcription"])],
    dependencies: [
        .package(path: "../AppCore"),
        .package(path: "../AudioCapture"),
        .package(path: "../ModelStore"),
        .package(path: "../SpeechNative"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.1"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.4", traits: ["Diarizer"]),
    ],
    targets: [
        .target(
            name: "Transcription",
            dependencies: [
                .product(name: "AppCore", package: "AppCore"),
                .product(name: "AudioCapture", package: "AudioCapture"),
                .product(name: "ModelStore", package: "ModelStore"),
                .product(name: "SpeechNative", package: "SpeechNative"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            swiftSettings: [.treatAllWarnings(as: .error)]),
        .testTarget(
            name: "TranscriptionTests",
            dependencies: [
                "Transcription", .product(name: "AppCoreTesting", package: "AppCore"),
                .product(name: "AudioCapture", package: "AudioCapture"),
            ]),
    ],
    swiftLanguageModes: [.v6]
)
