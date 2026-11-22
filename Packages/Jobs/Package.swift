// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Jobs",
    platforms: [.macOS(.v26)],
    products: [.library(name: "Jobs", targets: ["Jobs"])],
    dependencies: [
        .package(path: "../AppCore"),
        .package(path: "../Persistence"),
        .package(path: "../ModelStore"),
        .package(path: "../AudioCapture"),
        .package(path: "../Transcription"),
        .package(path: "../Processing"),
        .package(path: "../Export"),
        .package(path: "../Diarization"),
    ],
    targets: [
        .target(
            name: "Jobs",
            dependencies: [
                .product(name: "AppCore", package: "AppCore"),
                .product(name: "Persistence", package: "Persistence"),
                .product(name: "ModelStore", package: "ModelStore"),
                .product(name: "AudioCapture", package: "AudioCapture"),
                .product(name: "Transcription", package: "Transcription"),
                .product(name: "Processing", package: "Processing"),
                .product(name: "Export", package: "Export"),
                .product(name: "Diarization", package: "Diarization"),
            ],
            swiftSettings: [.treatAllWarnings(as: .error)]),
        .testTarget(
            name: "JobsTests",
            dependencies: [
                "Jobs",
                .product(name: "AppCoreTesting", package: "AppCore"),
                .product(name: "Persistence", package: "Persistence"),
                .product(name: "ModelStore", package: "ModelStore"),
                .product(name: "Transcription", package: "Transcription"),
                .product(name: "AudioCapture", package: "AudioCapture"),
                .product(name: "Export", package: "Export"),
            ]),
    ],
    swiftLanguageModes: [.v6]
)
