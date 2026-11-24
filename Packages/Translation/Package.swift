// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Translation",
    platforms: [.macOS(.v26)],
    products: [.library(name: "EarmarkTranslation", targets: ["EarmarkTranslation"])],
    dependencies: [
        .package(path: "../AppCore"),
        .package(path: "../NativeWorkerKit")
    ],
    targets: [
        // The target is named EarmarkTranslation (not Translation) so it never collides with Apple's Translation module.
        .target(
            name: "EarmarkTranslation", dependencies: [.product(name: "AppCore", package: "AppCore"), "NativeWorkerKit"],
            swiftSettings: [.treatAllWarnings(as: .error)]),
        .testTarget(
            name: "TranslationTests",
            dependencies: ["EarmarkTranslation", .product(name: "AppCoreTesting", package: "AppCore")]),
    ],
    swiftLanguageModes: [.v6]
)
