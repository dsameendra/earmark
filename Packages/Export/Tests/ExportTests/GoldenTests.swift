import AppCore
import Foundation
import Testing

@testable import Export

private struct GoldenCase: Sendable, CustomStringConvertible {
    var format: ExportFormat
    var name: String
    var configure: @Sendable (inout ExportOptions) -> Void
    var description: String { "\(format.rawValue)/\(name)" }
}

private let textFormats: [ExportFormat] = [.txt, .markdown, .html, .json, .csv, .srt, .vtt, .ass, .sbv, .ttml, .lrc]

private let goldenCases: [GoldenCase] = textFormats.flatMap { format -> [GoldenCase] in
    var cases = [
        GoldenCase(format: format, name: "default") { _ in },
        GoldenCase(format: format, name: "bilingual-en") {
            $0.translation = .bilingual
            $0.translationLanguage = "en"
        },
    ]
    if [.srt, .vtt, .ttml, .ass].contains(format) {
        cases.append(
            GoldenCase(format: format, name: "narrow") {
                $0.subtitle = SubtitleConstraints(maxCharsPerLine: 20, maxLinesPerCue: 2, minCueDuration: 1, maxCueDuration: 4)
            })
        cases.append(
            GoldenCase(format: format, name: "replace-si") {
                $0.translation = .replace
                $0.translationLanguage = "si"
            })
    }
    if [.txt, .markdown].contains(format) {
        cases.append(
            GoldenCase(format: format, name: "grouped-every5s") {
                $0.paragraphGrouping = true
                $0.timestamps = .everyNSeconds(5)
            })
    }
    if format == .txt {
        cases.append(GoldenCase(format: format, name: "with-ignored-no-speakers") {
            $0.includeIgnored = true
            $0.includeSpeakers = false
        })
    }
    return cases
}

@Suite("Golden files")
struct GoldenTests {
    @Test("EXP-AC-01: byte-identical to committed goldens", arguments: goldenCases)
    fileprivate func golden(_ c: GoldenCase) async throws {
        var options = ExportOptions(format: c.format)
        c.configure(&options)
        let artifact = try await ExportService().export(Fixture.document(), options: options)
        try Golden.check(artifact.data, format: c.format.rawValue, name: c.name)
        #expect(artifact.suggestedFilename == "Team Sync.\(c.format.fileExtension)")
    }
}
