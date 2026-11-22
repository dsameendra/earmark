// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [.treatAllWarnings(as: .error)]
let base: [Target.Dependency] = [
    .product(name: "AppCore", package: "AppCore"),
    .product(name: "DesignSystem", package: "DesignSystem"),
    "FeatureSupport",
]

let package = Package(
    name: "Features",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "FeatureSupport", targets: ["FeatureSupport"]),
        .library(name: "FeatureShell", targets: ["FeatureShell"]),
        .library(name: "FeatureHome", targets: ["FeatureHome"]),
        .library(name: "FeatureQueue", targets: ["FeatureQueue"]),
        .library(name: "FeatureLibrary", targets: ["FeatureLibrary"]),
        .library(name: "FeatureMeetings", targets: ["FeatureMeetings"]),
        .library(name: "FeatureLive", targets: ["FeatureLive"]),
        .library(name: "FeatureMenuBar", targets: ["FeatureMenuBar"]),
        .library(name: "FeatureSettings", targets: ["FeatureSettings"]),
        .library(name: "FeatureEditor", targets: ["FeatureEditor"]),
        .library(name: "FeatureOnboarding", targets: ["FeatureOnboarding"]),
    ],
    dependencies: [
        .package(path: "../AppCore"),
        .package(path: "../DesignSystem"),
        .package(path: "../Processing"),
        .package(path: "../LiveCaptions"),
        .package(path: "../Export"),
    ],
    targets: [
        .target(
            name: "FeatureSupport",
            dependencies: [.product(name: "AppCore", package: "AppCore"), .product(name: "DesignSystem", package: "DesignSystem")],
            swiftSettings: strict),
        .target(name: "FeatureHome", dependencies: base, swiftSettings: strict),
        .target(name: "FeatureQueue", dependencies: base, swiftSettings: strict),
        .target(name: "FeatureLibrary", dependencies: base, swiftSettings: strict),
        .target(name: "FeatureMeetings", dependencies: base, swiftSettings: strict),
        .target(name: "FeatureLive", dependencies: base + [.product(name: "LiveCaptions", package: "LiveCaptions")], swiftSettings: strict),
        .target(name: "FeatureMenuBar", dependencies: base + ["FeatureLive"], swiftSettings: strict),
        .target(
            name: "FeatureSettings",
            dependencies: base + [
                .product(name: "Processing", package: "Processing"), .product(name: "Export", package: "Export"),
                .product(name: "LiveCaptions", package: "LiveCaptions"),
            ], swiftSettings: strict),
        .target(
            name: "FeatureEditor",
            dependencies: base + [
                .product(name: "Processing", package: "Processing"), .product(name: "Export", package: "Export"),
            ], swiftSettings: strict),
        .target(name: "FeatureOnboarding", dependencies: base + ["FeatureSettings"], swiftSettings: strict),
        .target(
            name: "FeatureShell",
            dependencies: base + ["FeatureHome", "FeatureQueue", "FeatureLibrary", "FeatureMeetings", "FeatureLive", "FeatureEditor"],
            swiftSettings: strict),
        .testTarget(
            name: "FeaturesTests",
            dependencies: base + [
                .product(name: "AppCoreTesting", package: "AppCore"),
                "FeatureShell", "FeatureHome", "FeatureQueue", "FeatureLibrary", "FeatureMeetings", "FeatureLive", "FeatureMenuBar",
                "FeatureSettings", "FeatureEditor", "FeatureOnboarding", .product(name: "Processing", package: "Processing"),
                .product(name: "LiveCaptions", package: "LiveCaptions"),
            ]),
    ],
    swiftLanguageModes: [.v6]
)
