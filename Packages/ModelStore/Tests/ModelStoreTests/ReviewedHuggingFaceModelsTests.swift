import AppCore
import Foundation
import Testing
@testable import ModelStore

@Suite("Reviewed Hugging Face recipe selection")
struct ReviewedHuggingFaceModelsTests {
    @Test func rootOffersVariantsAndFolderSelectsOneWithoutChangingTheRecipe() throws {
        let all = try ReviewedHuggingFaceModels.resolve("argmaxinc/whisperkit-coreml")
        #expect(Set(all) == ["whisperkit/small", "whisperkit/large-v3-v20240930_626MB", "whisperkit/large-v3-v20240930_turbo_632MB"])
        let small = try #require(BuiltInCatalog.models.first { $0.id == "whisperkit/small" })
        let pinned = try #require(small.sourceURL)
        #expect(try ReviewedHuggingFaceModels.resolve(pinned.absoluteString) == [small.id])
        let floating = pinned.absoluteString.replacingOccurrences(of: BuiltInCatalog.Revision.whisperKit, with: "main")
        #expect(try ReviewedHuggingFaceModels.resolve(floating) == [small.id])
        #expect(small.sourceURL == pinned)
    }

    @Test func aDifferentCommitOrBranchCannotSilentlySelectReviewedWeights() {
        for revision in [String(repeating: "b", count: 40), "dev", "v1"] {
            #expect(throws: ReviewedHuggingFaceModels.UnsupportedSource.self) {
                try ReviewedHuggingFaceModels.resolve("https://huggingface.co/argmaxinc/whisperkit-coreml/tree/\(revision)")
            }
        }
    }

    @Test func rejectsUnknownFilesSiblingFoldersAndUnrunnableLegacyModels() {
        for source in [
            "unknown/whisper", "argmaxinc/whisperkit-coreml/tree/main/openai_whisper-small_216MB-extra",
            "argmaxinc/whisperkit-coreml/resolve/main/openai_whisper-small_216MB/config.json",
            "jbochi/madlad400-3b-mt/resolve/main/model-q4k.gguf",
        ] {
            #expect(throws: ReviewedHuggingFaceModels.UnsupportedSource.self) { try ReviewedHuggingFaceModels.resolve(source) }
        }
        #expect(BuiltInCatalog.models.first { $0.id == "coreml/whisper-small-sinhala" }?.isRunnable == false)
    }

    @Test func excludesCustomUnpinnedAndDisabledDescriptors() throws {
        let base = ModelDescriptor(id: "reviewed", displayName: "Test", kind: .asr, runtime: .other,
                                   languages: ["en"], sizeBytes: 100, license: LicenseInfo(spdx: "MIT"),
                                   sourceURL: URL(string: "https://huggingface.co/owner/model/tree/" + String(repeating: "a", count: 40)))
        var custom = base; custom.id = "custom"; custom.isCustom = true
        var floating = base; floating.id = "floating"; floating.sourceURL = URL(string: "https://huggingface.co/owner/model")
        var disabled = base; disabled.id = "disabled"; disabled.capabilities = ModelCapabilities(file: false)
        #expect(try ReviewedHuggingFaceModels.resolve("owner/model", catalog: [custom, floating, disabled, base]) == [base.id])
    }
}
