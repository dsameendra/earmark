// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ModelStore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "ModelStore", targets: ["ModelStore"])],
    dependencies: [
        .package(path: "../AppCore"),
        .package(path: "../NativeWorkerKit")

    ],
    targets: [
        .target(
            name: "ModelStore", dependencies: [.product(name: "AppCore", package: "AppCore"), "NativeWorkerKit"], swiftSettings: [.treatAllWarnings(as: .error)]),
        .testTarget(name: "ModelStoreTests", dependencies: ["ModelStore", .product(name: "AppCoreTesting", package: "AppCore")]),
    ],
    swiftLanguageModes: [.v6]
)
