// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Persistence",
    platforms: [.macOS(.v26)],
    products: [.library(name: "Persistence", targets: ["Persistence"])],
    dependencies: [
        .package(path: "../AppCore"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "Persistence",
            dependencies: [.product(name: "AppCore", package: "AppCore"), .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: [.treatAllWarnings(as: .error)]),
        .testTarget(
            name: "PersistenceTests",
            dependencies: [
                "Persistence", .product(name: "AppCoreTesting", package: "AppCore"), .product(name: "GRDB", package: "GRDB.swift"),
            ]),
    ],
    swiftLanguageModes: [.v6]
)
