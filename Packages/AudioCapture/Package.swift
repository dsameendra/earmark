// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AudioCapture",
    platforms: [.macOS(.v26)],
    products: [.library(name: "AudioCapture", targets: ["AudioCapture"])],
    dependencies: [
        .package(path: "../AppCore")

    ],
    targets: [
        .target(
            name: "AudioCapture", dependencies: [.product(name: "AppCore", package: "AppCore")],
            swiftSettings: [.treatAllWarnings(as: .error)]),
        .testTarget(name: "AudioCaptureTests", dependencies: ["AudioCapture", .product(name: "AppCoreTesting", package: "AppCore")]),
    ],
    swiftLanguageModes: [.v6]
)
