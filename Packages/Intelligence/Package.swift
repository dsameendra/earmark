// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Intelligence",
    platforms: [.macOS(.v26)],
    products: [.library(name: "EarmarkIntelligence", targets: ["EarmarkIntelligence"])],
    dependencies: [.package(path: "../AppCore")],
    targets: [
        // Named EarmarkIntelligence so it never collides with an Apple module. Depends on AppCore only; the app composes it.
        .target(
            name: "EarmarkIntelligence", dependencies: [.product(name: "AppCore", package: "AppCore")],
            swiftSettings: [.treatAllWarnings(as: .error)]),
        .testTarget(
            name: "IntelligenceTests",
            dependencies: ["EarmarkIntelligence", .product(name: "AppCoreTesting", package: "AppCore")]),
    ],
    swiftLanguageModes: [.v6]
)
