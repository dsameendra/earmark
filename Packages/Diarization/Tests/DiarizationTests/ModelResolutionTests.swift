import AppCore
import Foundation
import Testing

@testable import Diarization

@Suite("Model resolution") struct ModelResolutionTests {
    @Test func findsNestedDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("diar-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("a/b/speaker-diarization")
        try FileManager.default.createDirectory(at: nested.appendingPathComponent("Segmentation.mlmodelc"), withIntermediateDirectories: true)
        try Data().write(to: nested.appendingPathComponent("plda-parameters.json"))
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ModelFiles.directory(containingAll: ["Segmentation.mlmodelc", "plda-parameters.json"], under: root)?.lastPathComponent == "speaker-diarization")
        #expect(ModelFiles.directory(containingAll: ["Missing.mlmodelc"], under: root) == nil)
    }
}
