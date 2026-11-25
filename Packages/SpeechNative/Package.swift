// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SpeechNative",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SpeechNative", targets: ["SpeechNative"]),
        .library(name: "TranscribeCpp", targets: ["TranscribeCpp"]),
        .executable(name: "EarmarkSpeechWorker", targets: ["EarmarkSpeechWorker"]),
    ],
    dependencies: [.package(path: "../NativeWorkerKit")],
    targets: [
        .binaryTarget(name: "CTranscribe", path: "Vendor/TranscribeCpp.xcframework"),
        // Verbatim upstream Swift 5.9 wrapper. Earmark's wire/runtime code uses strict Swift 6.
        .target(name: "TranscribeCpp", dependencies: ["CTranscribe"], path: "Vendor/Swift",
                swiftSettings: [.swiftLanguageMode(.v5)],
                linkerSettings: [.linkedLibrary("c++"), .linkedLibrary("z"), .linkedFramework("Accelerate"),
                    .linkedFramework("Foundation"), .linkedFramework("Metal"), .linkedFramework("MetalKit")]),
        .target(name: "SpeechNative", dependencies: ["NativeWorkerKit"], swiftSettings: [.treatAllWarnings(as: .error)]),
        .executableTarget(name: "EarmarkSpeechWorker", dependencies: ["SpeechNative", "TranscribeCpp"],
                          swiftSettings: [.treatAllWarnings(as: .error)]),
        .testTarget(name: "SpeechNativeTests", dependencies: ["SpeechNative"]),
    ],
    swiftLanguageModes: [.v6]
)
