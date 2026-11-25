import Foundation
import NLLBNative
import Testing

private let modelFolder = ProcessInfo.processInfo.environment["EARMARK_NLLB_MODEL_DIR"]

@Suite("Native NLLB parity", .serialized, .enabled(if: modelFolder != nil))
struct NativeParityTests {
    private struct Golden: Decodable {
        struct Tokens: Decodable {
            let text: String
            let pieces: [String]
        }
        struct Translation: Decodable {
            let source: String
            let target: String
            let text: String
            let translation: String
        }
        let tokens: [Tokens]
        let translations: [Translation]
    }

    @Test func sentencePieceAndBeamSearchMatchPinnedPython() throws {
        let file = try #require(Bundle.module.url(forResource: "parity", withExtension: "json", subdirectory: "Fixtures"))
        let golden = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: file))
        let folder = try #require(modelFolder)
        let model = try NativeNLLBModel(folder: URL(fileURLWithPath: folder))
        #expect(throws: NativeNLLBError.self) { try model.translate("hello\0world", source: "eng_Latn", target: "sin_Sinh") }
        #expect(throws: NativeNLLBError.self) { try model.tokens(for: "hello\0world") }
        #expect(model.languageTags?.count == 202)
        #expect(model.languageTags?.contains("zho_Hant") == true)
        #expect(model.languageTags?.contains("kas_Deva") == true)
        #expect(throws: NativeNLLBError.self) { try model.translate("hello", source: "not-a-token", target: "sin_Sinh") }
        #expect(throws: NativeNLLBError.self) { try model.translate("hello", source: "eng_Latn", target: "not-a-token") }
        for row in golden.tokens { #expect(try model.tokens(for: row.text) == row.pieces) }
        for row in golden.translations { #expect(try model.translate(row.text, source: row.source, target: row.target) == row.translation) }
    }

    @Test func invalidModelFailsWithAnError() {
        #expect(throws: (any Error).self) { try NativeNLLBModel(folder: URL(fileURLWithPath: "/nonexistent/earmark-model")) }
    }
}
