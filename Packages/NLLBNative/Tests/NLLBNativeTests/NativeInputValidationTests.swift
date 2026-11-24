import Foundation
import NLLBNative
import Testing

@Suite("Native NLLB model input validation")
struct NativeInputValidationTests {
    @Test func malformedVocabularyFailsBeforeLoadingWeights() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("earmark-native-vocabulary-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vocabulary = root.appendingPathComponent("shared_vocabulary.txt")
        try Data("eng_Latn\nsin_Sinh\n".utf8).write(to: vocabulary)
        #expect(throws: NativeNLLBError(message: "This checkpoint does not contain the complete reviewed NLLB language-token inventory.")) {
            try NativeNLLBModel(folder: root)
        }
        try Data([0xFF, 0x00]).write(to: vocabulary)
        #expect(throws: NativeNLLBError(message: "The NLLB vocabulary is not valid UTF-8 text.")) { try NativeNLLBModel(folder: root) }
        let conflicting = root.appendingPathComponent("shared_vocabulary.json")
        try Data("[]".utf8).write(to: conflicting)
        #expect(throws: NativeNLLBError(message: "The NLLB folder has conflicting vocabulary files. Use a validated NLLB checkpoint.")) { try NativeNLLBModel(folder: root) }
        try FileManager.default.removeItem(at: conflicting)
        let file = try FileHandle(forWritingTo: vocabulary)
        try file.seek(toOffset: 16 * 1_024 * 1_024)
        try file.write(contentsOf: Data([0]))
        try file.close()
        #expect(throws: NativeNLLBError(message: "The NLLB shared vocabulary is missing, unsafe or oversized.")) { try NativeNLLBModel(folder: root) }
        try FileManager.default.removeItem(at: vocabulary)
        let target = root.appendingPathComponent("actual-vocabulary.txt")
        try Data("eng_Latn".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: vocabulary, withDestinationURL: target)
        #expect(throws: NativeNLLBError(message: "The NLLB shared vocabulary is missing, unsafe or oversized.")) { try NativeNLLBModel(folder: root) }
    }

    @Test func invalidThreadsAndRemoteFoldersNeverReachTheCBridge() {
        for threads in [Int.min, 0, 65, Int.max] {
            #expect(throws: NativeNLLBError(message: "Choose a local model folder and between 1 and 64 inference threads.")) {
                try NativeNLLBModel(folder: URL(fileURLWithPath: "/unused"), threads: threads)
            }
        }
        #expect(throws: NativeNLLBError(message: "Choose a local model folder and between 1 and 64 inference threads.")) {
            try NativeNLLBModel(folder: URL(string: "https://example.invalid/model")!)
        }
    }
}
