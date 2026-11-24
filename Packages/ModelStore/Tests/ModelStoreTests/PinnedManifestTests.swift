import AppCore
import Foundation
import Testing
@testable import ModelStore

@Suite("Pinned model artifact manifests")
struct PinnedManifestTests {
    private let digest = String(repeating: "a", count: 64)
    private func model(artifacts: [ModelArtifactDigest]) -> ModelDescriptor {
        ModelDescriptor(id: "test/pinned", displayName: "Pinned", kind: .translation, runtime: .other, languages: ["en", "de"],
                        sizeBytes: 3, license: LicenseInfo(spdx: "MIT"), sourceURL: URL(string: "https://huggingface.co/o/r/tree/" + String(repeating: "b", count: 40)),
                        provenance: ModelProvenance(profileID: "test", profileVersion: 1, artifacts: artifacts, validation: .formatChecked))
    }

    @Test func pinsTheChecksumEvenForFilesWithoutLFSMetaData() async throws {
        let resolver = HuggingFaceManifestResolver { _ in Data(#"[{"type":"file","path":"model.bin","size":3}]"#.utf8) }
        let files = try await resolver.files(for: model(artifacts: [ModelArtifactDigest(path: "model.bin", bytes: 3, sha256: digest)]))
        #expect(files.first?.sha256 == digest)
        #expect(files.first?.sizeBytes == 3)
    }

    @Test func rejectsMissingAndDuplicatePinnedInventoryEntries() async {
        let resolver = HuggingFaceManifestResolver { _ in Data(#"[{"type":"file","path":"model.bin","size":3}]"#.utf8) }
        let artifact = ModelArtifactDigest(path: "model.bin", bytes: 3, sha256: digest)
        let missing = ModelArtifactDigest(path: "tokenizer.json", bytes: 1, sha256: digest)
        await #expect(throws: (any Error).self) { try await resolver.files(for: model(artifacts: [artifact, missing])) }
        await #expect(throws: (any Error).self) { try await resolver.files(for: model(artifacts: [artifact, artifact])) }
    }

    @Test func rejectsAChangedTreeSizeOrHashBeforeDownloading() async {
        let expected = model(artifacts: [ModelArtifactDigest(path: "model.bin", bytes: 3, sha256: digest)])
        let changedSize = HuggingFaceManifestResolver { _ in Data(#"[{"type":"file","path":"model.bin","size":4}]"#.utf8) }
        await #expect(throws: (any Error).self) { try await changedSize.files(for: expected) }
        let changedHash = HuggingFaceManifestResolver { _ in
            let object: [[String: Any]] = [["type": "file", "path": "model.bin", "size": 3, "lfs": ["oid": String(repeating: "c", count: 64)]]]
            return try JSONSerialization.data(withJSONObject: object)
        }
        await #expect(throws: (any Error).self) { try await changedHash.files(for: expected) }
    }
}
