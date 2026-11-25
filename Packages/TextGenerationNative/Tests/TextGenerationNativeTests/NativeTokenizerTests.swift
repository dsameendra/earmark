import Foundation
import Testing
@testable import TextGenerationNative

private let modelRoot = ProcessInfo.processInfo.environment["EARMARK_GENERATIVE_MODEL_ROOT"]

@Suite("Actual native generative tokenizers", .serialized, .enabled(if: modelRoot != nil))
struct NativeTokenizerTests {
    @Test func exactVariantRoleTokensAndDiagnosticInferenceRejection() throws {
        let root = URL(fileURLWithPath: try #require(modelRoot))
        let cases: [(GenerativeProfile, String, [Int], Int)] = [
            (.hymt18, "hymt18-q4", [120000, 120006], 120007),
            (.hymt7, "hymt7-q4", [127958], 127962),
            (.gemma4, "gemma4-q4", [2, 105], 107),
            (.gemma12, "gemma12-q4", [2, 105], 107),
        ]
        for (profile, folder, prefix, suffix) in cases {
            let model = try NativeTextModel(folder: root.appendingPathComponent(folder), profile: profile, tokenizerOnly: true)
            #expect(model.tokenizerOnly)
            let tokens = try model.tokens(text: "Hello world.", source: "en", target: "de")
            #expect(Array(tokens.prefix(prefix.count)) == prefix)
            #expect(tokens.last == suffix)
            #expect(throws: NativeTextError.self) { try model.translate(text: "Hello world.", source: "en", target: "de") }
        }
    }

    @Test func oversizedVariantIsRejectedBeforeNativeAllocation() throws {
        let root = URL(fileURLWithPath: try #require(modelRoot))
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("earmark-native-variant-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        // Hard-link owned validation data: no copy, mutation or removal of the source.
        try FileManager.default.linkItem(at: root.appendingPathComponent("gemma12-q4/" + GenerativeProfile.gemma12.filename),
                                        to: temporary.appendingPathComponent(GenerativeProfile.gemma4.filename))
        #expect(throws: (any Error).self) { try NativeTextModel(folder: temporary, profile: .gemma4) }
    }
}
