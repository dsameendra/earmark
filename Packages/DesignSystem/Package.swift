// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DesignSystem",
    platforms: [.macOS(.v26)],
    products: [.library(name: "DesignSystem", targets: ["DesignSystem"])],
    dependencies: [
        .package(path: "../AppCore")

    ],
    targets: [
        .target(
            name: "DesignSystem", dependencies: [.product(name: "AppCore", package: "AppCore")],
            swiftSettings: [.treatAllWarnings(as: .error)]),
        .testTarget(name: "DesignSystemTests", dependencies: ["DesignSystem", .product(name: "AppCoreTesting", package: "AppCore")]),
    ],
    swiftLanguageModes: [.v6]
)
