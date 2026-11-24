import Foundation
import Testing
@testable import TextGenerationNative

@Suite("Finite generative translation profiles")
struct GenerativeProfileTests {
    @Test func rejectsUnsupportedPairsAndControlDelimitersBeforeNativeInference() throws {
        #expect(!GenerativeProfile.hymt18.supports(source: "si", target: "en"))
        #expect(GenerativeProfile.hymt18.supports(source: "zh-Hant", target: "en"))
        #expect(!GenerativeProfile.gemma4.supports(source: "si", target: "en"))
        #expect(!GenerativeProfile.gemma12.supports(source: "si", target: "en"))
        #expect(!GenerativeProfile.gemma4.supports(source: "en", target: "en"))
        #expect(!GenerativeProfile.gemma4.supports(source: "made-up-language", target: "en"))
        for marker in ["<|im_start|>", "<｜hy_Assistant｜>", "<bos>", "<end_of_turn>", "hello\0world"] {
            #expect(throws: NativeTextError.self) { try GenerativeProfile.gemma4.content(text: marker, source: "en", target: "de") }
        }
        #expect(throws: NativeTextError.self) { try GenerativeProfile.hymt18.content(text: String(repeating: "a", count: 16_385), source: "en", target: "de") }
        #expect(throws: NativeTextError.self) { try GenerativeProfile.hymt18.content(text: "hello", source: "si", target: "de") }
    }

    @Test func gemmaPromptMatchesPinnedJinjaReferenceWithoutDuplicatingBOS() throws {
        let path = try #require(Bundle.module.url(forResource: "gemma-en-de", withExtension: "txt", subdirectory: "Fixtures"))
        let expected = try String(contentsOf: path, encoding: .utf8)
        let prompt = try GenerativeProfile.gemma4.content(text: "  Hello world.  ", source: "en", target: "de")
        #expect("<bos>" + prompt == expected)
        #expect(try GenerativeProfile.gemma12.content(text: "Hello world.", source: "en", target: "de") == prompt)
    }

    @Test func hymtUsesThePinnedDefaultInstructionWithoutASystemPrompt() throws {
        let expected = "Translate the following text into German. Note that you should only output the translated result without any additional explanation:\n\nHello world."
        #expect(try GenerativeProfile.hymt18.content(text: "Hello world.", source: "en", target: "de") == expected)
        #expect(try GenerativeProfile.hymt7.content(text: "Hello world.", source: "en", target: "de") == expected)
    }
}
