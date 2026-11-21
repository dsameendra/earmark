// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Processing",
    platforms: [.macOS(.v26)],
    products: [.library(name: "Processing", targets: ["Processing"])],
    dependencies: [.package(path: "../AppCore")],
    targets: [
        .target(
            name: "Processing",
            dependencies: [.product(name: "AppCore", package: "AppCore")],
            swiftSettings: [.treatAllWarnings(as: .error)]),
        .testTarget(
            name: "ProcessingTests",
            dependencies: ["Processing", .product(name: "AppCoreTesting", package: "AppCore")]),
    ],
    swiftLanguageModes: [.v6]
)
