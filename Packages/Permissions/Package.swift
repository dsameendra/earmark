// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Permissions",
    platforms: [.macOS(.v26)],
    products: [.library(name: "Permissions", targets: ["Permissions"])],
    dependencies: [
        .package(path: "../AppCore")
    ],
    targets: [
        .target(
            name: "Permissions", dependencies: [.product(name: "AppCore", package: "AppCore")],
            swiftSettings: [.treatAllWarnings(as: .error)]),
        .testTarget(name: "PermissionsTests", dependencies: ["Permissions"]),
    ],
    swiftLanguageModes: [.v6]
)
