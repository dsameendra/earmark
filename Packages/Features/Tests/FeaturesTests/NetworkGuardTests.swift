import Foundation
import Testing

/// Source guard for the privacy claim "model downloads are the only first-party network path" (SCR-006, QA code review
/// 2026-11-22 gap 8). Network APIs may appear only in the ModelStore package (Hugging Face manifest and downloads, HTTPS plus
/// host allow-list) and in the Sparkle update controller. `NWPathMonitor` (reachability, no traffic) is not a transport and is
/// deliberately not on the banned list.
@Suite("Network guard") struct NetworkGuardTests {
    /// Repository root, located from this file (`Packages/Features/Tests/FeaturesTests/`).
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// APIs that open a network connection or load remote content.
    static let bannedAPIs = [
        "URLSession", "NSURLConnection", "NWConnection", "NWListener", "NWConnectionGroup", "WKWebView", "CFSocket",
        "CFStreamCreatePairWithSocket", "NSStream.getStreamsToHost", "SPUStandardUpdaterController", "import Sparkle",
        "SUUpdater",
    ]

    /// Path prefixes (relative to the repository root) allowed to use them, with the reason.
    static let allowedPrefixes: [String: String] = [
        "Packages/ModelStore/Sources/": "model manifest and downloads: HTTPS only, host allow-list, redirect checks",
        "App/AppUpdateController.swift": "Sparkle: dormant unless a valid HTTPS feed and Ed25519 key are configured (SCR-006)",
    ]

    static let scannedExtensions: Set<String> = ["swift", "m", "mm", "cpp", "c", "h", "hpp"]

    struct Hit: Equatable {
        let path: String
        let api: String
    }

    /// Source roots: every package's `Sources`, the app target and the native runtime bridge.
    static func sourceFiles() -> [(path: String, text: String)] {
        let fm = FileManager.default
        var roots: [URL] = [repoRoot.appendingPathComponent("App"), repoRoot.appendingPathComponent("NativeRuntime")]
        let packages = repoRoot.appendingPathComponent("Packages")
        for name in (try? fm.contentsOfDirectory(atPath: packages.path)) ?? [] {
            roots.append(packages.appendingPathComponent(name).appendingPathComponent("Sources"))
        }
        var out: [(String, String)] = []
        for root in roots {
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where scannedExtensions.contains(url.pathExtension) {
                guard !url.path.contains("/.build/"), let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
                out.append((String(url.path.dropFirst(repoRoot.path.count + 1)), raw))
            }
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// Banned API uses in `files` (comments are ignored) that are not under an allowed prefix.
    static func violations(in files: [(path: String, text: String)], allowed: Set<String>) -> [Hit] {
        var hits: [Hit] = []
        for file in files where !allowed.contains(where: { file.path.hasPrefix($0) }) {
            let code = file.text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            for api in bannedAPIs where code.contains(api) { hits.append(Hit(path: file.path, api: api)) }
        }
        return hits
    }

    @Test func sourcesAreFound() {
        let files = Self.sourceFiles()
        #expect(files.count > 100, "guard is scanning \(Self.repoRoot.path)")
        #expect(files.contains { $0.path.hasPrefix("App/") }, "App sources not found")
        #expect(files.contains { $0.path.hasPrefix("Packages/ModelStore/Sources/") }, "ModelStore sources not found")
    }

    @Test func networkAPIsStayInModelStoreAndTheUpdateController() {
        let hits = Self.violations(in: Self.sourceFiles(), allowed: Set(Self.allowedPrefixes.keys))
        #expect(
            hits.isEmpty,
            "Network APIs are limited to ModelStore and the Sparkle update controller (privacy claim); found: \(hits.map { "\($0.path): \($0.api)" })"
        )
    }

    @Test func allowedPlacesStillNeedTheirAllowance() {
        let files = Self.sourceFiles()
        for prefix in Self.allowedPrefixes.keys {
            let uses = files.filter { $0.path.hasPrefix(prefix) && Self.bannedAPIs.contains(where: $0.text.contains) }
            #expect(!uses.isEmpty, "\(prefix) no longer uses a network API; drop its allowance")
        }
    }

    @Test func theGuardDetectsAViolation() {
        let files = [(path: "Packages/Dictation/Sources/Dictation/Leak.swift", text: "let s = URLSession.shared\n// NWConnection in a comment")]
        #expect(Self.violations(in: files, allowed: []) == [Hit(path: "Packages/Dictation/Sources/Dictation/Leak.swift", api: "URLSession")])
        let allowed = [(path: "Packages/ModelStore/Sources/ModelStore/X.swift", text: "URLSession.shared")]
        #expect(Self.violations(in: allowed, allowed: Set(Self.allowedPrefixes.keys)).isEmpty)
    }
}
