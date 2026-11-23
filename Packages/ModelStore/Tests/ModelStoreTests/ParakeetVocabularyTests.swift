import Foundation
import Testing
@testable import ModelStore

@Suite("Legacy Parakeet vocabulary compatibility")
struct ParakeetVocabularyTests {
    @Test("unknown legacy data cannot become the runtime vocabulary")
    func rejectsUnknownData() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("unverified".utf8).write(to: folder.appendingPathComponent("parakeet_v3_vocab.json"))
        #expect(throws: (any Error).self) { try ParakeetVocabularyCompatibility.repair(in: folder) }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("parakeet_vocab.json").path))
    }

    @Test("an existing canonical vocabulary is never replaced")
    func preservesExistingCanonical() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let canonical = folder.appendingPathComponent("parakeet_vocab.json")
        try Data("existing".utf8).write(to: canonical)
        try Data("legacy".utf8).write(to: folder.appendingPathComponent("parakeet_v3_vocab.json"))
        try ParakeetVocabularyCompatibility.repair(in: folder)
        #expect(try Data(contentsOf: canonical) == Data("existing".utf8))
    }

    @Test("the pinned real legacy vocabulary is repaired offline", .enabled(if: ProcessInfo.processInfo.environment["EARMARK_PARAKEET_MODEL"] != nil))
    func repairsPinnedVocabulary() throws {
        let source = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["EARMARK_PARAKEET_MODEL"]))
            .appendingPathComponent("parakeet_v3_vocab.json")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = try Data(contentsOf: source)
        try original.write(to: folder.appendingPathComponent("parakeet_v3_vocab.json"))
        try ParakeetVocabularyCompatibility.repair(in: folder)
        #expect(try Data(contentsOf: folder.appendingPathComponent("parakeet_vocab.json")) == original)
        #expect(try Data(contentsOf: folder.appendingPathComponent("parakeet_v3_vocab.json")) == original)
    }
}
