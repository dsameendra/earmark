// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "ModelFormats", platforms: [.macOS(.v26)],
    products: [.library(name: "ModelFormats", targets: ["ModelFormats"])],
    targets: [
        .target(name: "ModelFormats", swiftSettings: [.treatAllWarnings(as: .error)]),
        .testTarget(name: "ModelFormatsTests", dependencies: ["ModelFormats"]),
    ], swiftLanguageModes: [.v6]
)
