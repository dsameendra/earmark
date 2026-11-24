import Foundation
import NLLBNative
import Testing

private let madladFolder = ProcessInfo.processInfo.environment["EARMARK_MADLAD_MODEL_DIR"]

@Suite("MADLAD native T5 parity", .serialized, .enabled(if: madladFolder != nil))
struct MADLADNativeTests {
    private struct Reference: Decodable {
        struct Row: Decodable {
            let source: String
            let target: String
            let text: String
            let translation: String
            let sourcePieces: [String]
        }
        let rows: [Row]
    }

    @Test func tokenizerAndDecoderMatchPinnedReferenceAcrossScripts() throws {
        let fixture = try #require(Bundle.module.url(forResource: "madlad-parity", withExtension: "json", subdirectory: "Fixtures"))
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: fixture))
        let model = try NativeNLLBModel(folder: URL(fileURLWithPath: #require(madladFolder)), profile: .madlad)
        for row in reference.rows {
            #expect(try model.tokens(for: "<2\(row.target)> " + row.text) + ["</s>"] == row.sourcePieces)
            #expect(try model.translate(row.text, source: row.source, target: row.target) == row.translation)
        }
    }

    @Test func rejectsUnknownTargetsAndOversizedInput() throws {
        let model = try NativeNLLBModel(folder: URL(fileURLWithPath: #require(madladFolder)), profile: .madlad)
        #expect(throws: NativeNLLBError.self) { try model.translate("Hello", source: "en", target: "no-such-language") }
        #expect(throws: NativeNLLBError.self) {
            try model.translate(String(repeating: "meeting ", count: 2_000), source: "en", target: "de")
        }
    }
}
