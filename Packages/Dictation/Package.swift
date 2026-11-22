// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Dictation",
    platforms: [.macOS(.v26)],
    products: [.library(name: "Dictation", targets: ["Dictation"])],
    dependencies: [
        .package(path: "../AppCore"),
        .package(path: "../DesignSystem"),
        .package(path: "../Features"),
    ],
    targets: [
        .target(
            name: "Dictation",
            dependencies: [
                .product(name: "AppCore", package: "AppCore"),
                .product(name: "DesignSystem", package: "DesignSystem"),
                .product(name: "FeatureSupport", package: "Features"),
            ],
            swiftSettings: [.treatAllWarnings(as: .error)]),
        .testTarget(
            name: "DictationTests",
            dependencies: ["Dictation", .product(name: "AppCoreTesting", package: "AppCore")]),
    ],
    swiftLanguageModes: [.v6]
)
