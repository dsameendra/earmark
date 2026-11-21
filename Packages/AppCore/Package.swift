// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AppCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AppCore", targets: ["AppCore"]),
        .library(name: "AppCoreTesting", targets: ["AppCoreTesting"]),
    ],
    targets: [
        .target(name: "AppCore", swiftSettings: [.treatAllWarnings(as: .error)]),
        .target(name: "AppCoreTesting", dependencies: ["AppCore"], swiftSettings: [.treatAllWarnings(as: .error)]),
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore", "AppCoreTesting"]),
    ],
    swiftLanguageModes: [.v6]
)
