// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Models",
    platforms: [.macOS(.v26)],
    products: [.library(name: "Models", targets: ["Models"])],
    dependencies: [
        .package(path: "../AppCore")

    ],
    targets: [
        .target(
            name: "Models", dependencies: [.product(name: "AppCore", package: "AppCore")], swiftSettings: [.treatAllWarnings(as: .error)]),
        .testTarget(name: "ModelsTests", dependencies: ["Models", .product(name: "AppCoreTesting", package: "AppCore")]),
    ],
    swiftLanguageModes: [.v6]
)
