// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Meetings",
    platforms: [.macOS(.v26)],
    products: [.library(name: "Meetings", targets: ["Meetings"])],
    dependencies: [
        .package(path: "../AppCore")

    ],
    targets: [
        .target(
            name: "Meetings", dependencies: [.product(name: "AppCore", package: "AppCore")], swiftSettings: [.treatAllWarnings(as: .error)]),
        .testTarget(name: "MeetingsTests", dependencies: ["Meetings", .product(name: "AppCoreTesting", package: "AppCore")]),
    ],
    swiftLanguageModes: [.v6]
)
