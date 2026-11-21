// swift-tools-version: 6.0
import PackageDescription
// Spike only. Language mode v5 to keep Core Audio C callbacks simple; production code should be Swift 6 mode.
let package = Package(
    name: "capture-spike",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "capture-spike",
            path: "Sources/capture-spike",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                // Embed Info.plist so TCC sees purpose strings (mic + NSAudioCaptureUsageDescription).
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Info.plist"])
            ]
        )
    ]
)
