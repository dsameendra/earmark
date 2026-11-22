import DesignSystem
import Foundation
import Testing

@testable import FeatureOnboarding
@testable import FeatureSettings
@testable import FeatureShell

/// T33 coverage: no stock glyph that `DSSymbol` replaces may reappear as an inline string in the Features sources.
/// Retained stock glyphs are marked with a trailing `// stock-chrome: <reason>` comment on the same line.
@Suite("Symbol codemod") struct SymbolCodemodTests {
    private func featureSourceFiles() throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let walker = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" && $0.lastPathComponent != "HomeView.swift" }
    }

    @Test func noCoveredStockNameRemainsInline() throws {
        let covered = Set(DSSymbol.allCases.flatMap(\.replacedStockNames)).map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        // Inline use: `systemImage: "x"`, `systemName: "x"`, `static let y = "x"`, `case .z: "x"`, `{ "x" }`.
        let pattern = "(systemImage|systemName):\\s*\"(\(covered))\"|static let \\w+ = \"(\(covered))\"|^\\s*case [^:]+:\\s*\"(\(covered))\"\\s*(//.*)?$|\\{\\s*\"(\(covered))\"\\s*\\}"
        let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        var offenders: [String] = []
        for file in try featureSourceFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let l = String(line)
                if l.contains("stock-chrome:") { continue }
                if regex.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) != nil { offenders.append("\(file.lastPathComponent):\(index + 1): \(l.trimmingCharacters(in: .whitespaces))") }
            }
        }
        #expect(offenders.isEmpty, Comment(rawValue: offenders.joined(separator: "\n")))
    }

    @Test func retainedStockGlyphsAreDocumented() throws {
        for file in try featureSourceFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n") where line.contains("stock-chrome:") {
                #expect(line.contains("stock-chrome: ") && !line.hasSuffix("stock-chrome: "), Comment(rawValue: "\(file.lastPathComponent): needs a reason"))
            }
        }
    }

    @Test func appSectionSymbolsBackTheFallbackNames() {
        for section in AppSection.allCases { #expect(section.systemImage == section.symbol.systemImageName) }
        #expect(AppSection.home.symbol == .home && AppSection.live.symbol == .liveCaptions && AppSection.recentlyDeleted.symbol == .recentlyDeleted)
    }

    @Test func settingsSectionSymbolsMatchTheirFallbacks() {
        for section in SettingsSection.allCases {
            if let symbol = section.symbol { #expect(section.systemImage == symbol.systemImageName, Comment(rawValue: "\(section)")) }
        }
    }
}
