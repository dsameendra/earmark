import Foundation
import Testing

/// Source guards for the M8 design rules (T31, `specs/design/m8-handoff.md` section 7):
/// 1. No glass on content: `GlassCard`/`GlassPanel` are banned in Features, and any file that applies glass
///    (`.glassEffect`, `.glassBackground`, `.dsGlass`, glass button styles, `GlassEffectContainer`, `DSGlassGroup`)
///    must carry a `// glass-layer: sidebar|toolbar|floater` marker naming which of the three budgeted layers it is.
/// 2. Tokens only: no literal colour construction (`Color(red:`, `Color(hex:`, `NSColor(`, ...) in views, including the
///    LiveCaptions and Dictation panel packages.
@Suite("Design guards") struct DesignGuardTests {
    /// `Packages/Features/Sources`, located from this file so the cwd does not matter.
    static let sourcesRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")

    struct SourceFile {
        let path: String  // relative to Sources
        let code: String  // comments stripped
        let raw: String
    }

    static func sourceFiles() -> [SourceFile] {
        guard let walker = FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil) else { return [] }
        var out: [SourceFile] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let code = raw.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            out.append(SourceFile(path: String(url.path.dropFirst(sourcesRoot.path.count + 1)), code: code, raw: raw))
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Packages outside Features that host floating panels (live caption overlay, dictation HUD). Only the glass
    /// rules apply to them: each glass use must be a marked `floater` (the third budgeted layer).
    static let extraGlassRoots: [(name: String, url: URL)] = ["LiveCaptions", "Dictation"].map {
        (
            $0,
            sourcesRoot.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("\($0)/Sources")
        )
    }

    /// Features sources plus the panel packages (paths prefixed `LiveCaptions/` and `Dictation/`).
    static func glassScanFiles() -> [SourceFile] {
        var out = sourceFiles()
        for root in extraGlassRoots {
            guard let walker = FileManager.default.enumerator(at: root.url, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let code = raw.split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
                out.append(SourceFile(path: root.name + "/" + String(url.path.dropFirst(root.url.path.count + 1)), code: code, raw: raw))
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    static func contains(_ file: SourceFile, anyOf patterns: [String]) -> Bool {
        patterns.contains { file.code.contains($0) }
    }

    // MARK: Glass

    static let bannedContentGlass = ["GlassCard", "GlassPanel"]
    static let glassAPIs = [
        ".glassEffect(", ".glassBackground(", ".dsGlass(", "GlassEffectContainer", "DSGlassGroup", ".buttonStyle(.glass",
        ".glassProminent", "NSGlassEffectView",
    ]

    @Test func sourcesAreFound() { #expect(Self.sourceFiles().count > 20, "guard is scanning \(Self.sourcesRoot.path)") }

    @Test func noGlassOnContentComponents() {
        let offenders = Self.sourceFiles().filter { Self.contains($0, anyOf: Self.bannedContentGlass) }.map(\.path)
        #expect(offenders.isEmpty, "GlassCard/GlassPanel put glass on content; use SheetCard/InsetCard: \(offenders)")
    }

    @Test func glassRequiresALayerMarker() {
        let markers = DSGlassMarkers.allowed.map { "// glass-layer: \($0)" }
        var offenders: [String] = []
        for file in Self.glassScanFiles() where Self.contains(file, anyOf: Self.glassAPIs) {
            if !markers.contains(where: { file.raw.contains($0) }) { offenders.append(file.path) }
        }
        #expect(
            offenders.isEmpty,
            "Glass is limited to sidebar, one toolbar group and one transient floater. Add '// glass-layer: sidebar|toolbar|floater' (and justify) or use a solid card: \(offenders)"
        )
    }

    @Test func panelPackagesAreScanned() {
        let paths = Self.glassScanFiles().map(\.path)
        #expect(paths.contains { $0.hasPrefix("LiveCaptions/") }, "LiveCaptions sources not found")
        #expect(paths.contains { $0.hasPrefix("Dictation/") }, "Dictation sources not found")
    }

    @Test func panelPackageGlassIsAFloater() {
        for file in Self.glassScanFiles() where file.path.hasPrefix("LiveCaptions/") || file.path.hasPrefix("Dictation/") {
            if Self.contains(file, anyOf: Self.glassAPIs) {
                #expect(file.raw.contains("// glass-layer: floater"), "\(file.path) hosts a panel and must be marked floater")
            }
        }
    }

    @Test func glassMarkersOnlyInFilesThatUseGlass() {
        let markers = DSGlassMarkers.allowed.map { "// glass-layer: \($0)" }
        let stale = Self.glassScanFiles().filter { f in
            markers.contains(where: { f.raw.contains($0) }) && !Self.contains(f, anyOf: Self.glassAPIs)
        }.map(\.path)
        #expect(stale.isEmpty, "glass-layer marker without glass: \(stale)")
    }

    // MARK: Tokens

    static let literalColorPatterns = [
        "Color(red:", "Color(hex:", "Color(white:", "Color(.sRGB", "Color(.displayP3", "NSColor(", "UIColor(", "#colorLiteral",
        "srgbRed:", "deviceRed:",
    ]

    /// Files allowed to build colours from data (not from design values), with the reason.
    static let literalColorAllowlist: [String: String] = [
        "FeatureEditor/WordFlow.swift": "renders a user-chosen speaker colour persisted as hex (SpeakerColorSpec.hex)",
        "FeatureWorkspace/MarkdownTextEditor.swift": "bridges DSColor tokens to NSColor for the AppKit text view (no literal values)",
        "FeatureSettings/PreferenceViews.swift": "caption preset text colour is user data (hex string) in the live preview",
        "LiveCaptions/LiveCaptions/CaptionPresets.swift": "decodes the user-chosen caption colour persisted as a hex string (CaptionStyle.color)",
    ]

    @Test func noLiteralColoursOutsideAllowlist() {
        // Features plus the panel packages (LiveCaptions overlay, Dictation HUD).
        let offenders = Self.glassScanFiles().filter {
            Self.literalColorAllowlist[$0.path] == nil && Self.contains($0, anyOf: Self.literalColorPatterns)
        }.map(\.path)
        #expect(offenders.isEmpty, "Use DSColor/DSPalette tokens instead of literal colours: \(offenders)")
    }

    @Test func allowlistHasNoStaleEntries() {
        let files = Dictionary(uniqueKeysWithValues: Self.glassScanFiles().map { ($0.path, $0) })
        for path in Self.literalColorAllowlist.keys {
            guard let f = files[path] else {
                Issue.record("allowlisted file missing: \(path)")
                continue
            }
            #expect(Self.contains(f, anyOf: Self.literalColorPatterns), "\(path) no longer needs its allowlist entry")
        }
    }
}

private enum DSGlassMarkers {
    /// Mirrors `DSGlass.allowedLayerMarkers` in DesignSystem (kept literal so a rename there is noticed here).
    static let allowed = ["sidebar", "toolbar", "floater"]
}
