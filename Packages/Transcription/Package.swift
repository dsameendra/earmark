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
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.1"),
    ],
    targets: [
        .target(
            name: "Transcription",
            dependencies: [
                .product(name: "AppCore", package: "AppCore"),
                .product(name: "AudioCapture", package: "AudioCapture"),
                .product(name: "ModelStore", package: "ModelStore"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
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
