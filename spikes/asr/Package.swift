// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "asr-poc",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.1"),
    ],
    targets: [
        .executableTarget(
            name: "asr-poc",
            dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift")]
        )
    ]
)
