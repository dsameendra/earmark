import Foundation
import NLLBNative
import Testing

private let multilingualModel = ProcessInfo.processInfo.environment["EARMARK_NLLB_MODEL_DIR"]

/// Native execution checks, not an independent translation-quality benchmark.
@Suite("NLLB multilingual native execution", .serialized, .enabled(if: multilingualModel != nil))
struct MultilingualNativeTests {
    @Test(arguments: ["deu_Latn", "fra_Latn", "spa_Latn", "hin_Deva", "tam_Taml", "jpn_Jpan", "arb_Arab"])
    func translatesOutsideSinhala(target: String) throws {
        let model = try NativeNLLBModel(folder: URL(fileURLWithPath: #require(multilingualModel)))
        let text = try model.translate("The meeting starts tomorrow morning.", source: "eng_Latn", target: target)
        #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(text != "The meeting starts tomorrow morning.")
        #expect(!text.contains("</s>"))
        print("NLLB native en→\(target): \(text)")
    }
}
