// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NLLBNative",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "NLLBNative", targets: ["NLLBNative"]),
        .executable(name: "EarmarkNLLBWorker", targets: ["EarmarkNLLBWorker"]),
    ],
    dependencies: [.package(path: "../NativeWorkerKit")],
    targets: [
        .binaryTarget(name: "EarmarkNLLBCore", path: "Vendor/EarmarkNLLBCore.xcframework"),
        .target(
            name: "NLLBNative", dependencies: ["EarmarkNLLBCore"],
            swiftSettings: [.treatAllWarnings(as: .error)],
            linkerSettings: [.linkedFramework("Accelerate"), .linkedLibrary("c++")]),
        .executableTarget(name: "EarmarkNLLBWorker", dependencies: ["NLLBNative", "NativeWorkerKit"], path: "Sources/EarmarkNLLBWorker"),
        .testTarget(name: "NLLBNativeTests", dependencies: ["NLLBNative"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v6]
)
