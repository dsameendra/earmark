// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LiveCaptions",
    platforms: [.macOS(.v26)],
    products: [.library(name: "LiveCaptions", targets: ["LiveCaptions"])],
    dependencies: [
        .package(path: "../AppCore"),
        .package(path: "../DesignSystem"),
    ],
    targets: [
        .target(
            name: "LiveCaptions",
            dependencies: [
                .product(name: "AppCore", package: "AppCore"),
                .product(name: "DesignSystem", package: "DesignSystem"),
            ],
            swiftSettings: [.treatAllWarnings(as: .error)]),
        .testTarget(
            name: "LiveCaptionsTests",
            dependencies: ["LiveCaptions", .product(name: "AppCoreTesting", package: "AppCore")]),
    ],
    swiftLanguageModes: [.v6]
)
