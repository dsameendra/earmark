// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TextGenerationNative", platforms: [.macOS(.v26)],
    products: [
        .library(name: "TextModelProfiles", targets: ["TextModelProfiles"]),
        .library(name: "TextGenerationNative", targets: ["TextGenerationNative"]),
        .executable(name: "EarmarkTextWorker", targets: ["EarmarkTextWorker"]),
    ],
    dependencies: [.package(path: "../NativeWorkerKit")],
    targets: [
        .binaryTarget(name: "EarmarkLlama", path: "Vendor/EarmarkLlama.xcframework"),
        .target(name: "TextModelProfiles", swiftSettings: [.treatAllWarnings(as: .error)]),
        .target(name: "TextGenerationNative", dependencies: ["EarmarkLlama", "TextModelProfiles"], swiftSettings: [.treatAllWarnings(as: .error)]),
        .executableTarget(name: "EarmarkTextWorker", dependencies: ["TextGenerationNative", "NativeWorkerKit"], swiftSettings: [.treatAllWarnings(as: .error)]),
        .testTarget(name: "TextGenerationNativeTests", dependencies: ["TextGenerationNative"], resources: [.copy("Fixtures")]),
    ], swiftLanguageModes: [.v6]
)
