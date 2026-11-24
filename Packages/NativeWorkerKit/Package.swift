// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NativeWorkerKit", platforms: [.macOS(.v26)],
    products: [.library(name: "NativeWorkerKit", targets: ["NativeWorkerKit"])],
    targets: [
        .target(name: "NativeWorkerKit", swiftSettings: [.treatAllWarnings(as: .error)]),
        .testTarget(name: "NativeWorkerKitTests", dependencies: ["NativeWorkerKit"]),
    ], swiftLanguageModes: [.v6]
)
