// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Export",
    platforms: [.macOS(.v26)],
    products: [.library(name: "Export", targets: ["Export"])],
    dependencies: [
        .package(path: "../AppCore"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        .target(
            name: "Export",
            dependencies: [.product(name: "AppCore", package: "AppCore"), .product(name: "ZIPFoundation", package: "ZIPFoundation")],
            swiftSettings: [.treatAllWarnings(as: .error)]),
        .testTarget(
            name: "ExportTests",
            dependencies: [
                "Export", .product(name: "AppCoreTesting", package: "AppCore"), .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]),
    ],
    swiftLanguageModes: [.v6]
)
