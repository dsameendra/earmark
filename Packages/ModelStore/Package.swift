// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ModelStore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "ModelStore", targets: ["ModelStore"]), .library(name: "ModelLanguageProfiles", targets: ["ModelLanguageProfiles"])],
    dependencies: [
        .package(path: "../AppCore"),
        .package(path: "../NativeWorkerKit")

    ],
    targets: [
        .target(name: "ModelLanguageProfiles", swiftSettings: [.treatAllWarnings(as: .error)]),
        .target(
            name: "ModelStore", dependencies: [.product(name: "AppCore", package: "AppCore"), "NativeWorkerKit", "ModelLanguageProfiles"], swiftSettings: [.treatAllWarnings(as: .error)]),
        .testTarget(name: "ModelStoreTests", dependencies: ["ModelStore", .product(name: "AppCoreTesting", package: "AppCore")]),
    ],
    swiftLanguageModes: [.v6]
)
