import Foundation
import Testing
@testable import ModelStore

@Suite("Hugging Face import source inspection")
struct HuggingFaceImportTests {
    @Test func repositoryAndPinnedFolder() throws {
        let repo = try HuggingFaceImportLocation(" mlx-community/Qwen3-ASR-0.6B-4bit ")
        #expect(repo.repository == "mlx-community/Qwen3-ASR-0.6B-4bit")
        #expect(repo.revision == "main" && repo.selection == .repository)
        let sha = String(repeating: "a", count: 40)
        let folder = try HuggingFaceImportLocation("https://huggingface.co/argmaxinc/whisperkit-coreml/tree/\(sha)/openai_whisper-small_216MB")
        #expect(folder.revision == sha)
        #expect(folder.path == "openai_whisper-small_216MB" && folder.selection == .folder)
        #expect(HuggingFaceImportLocation.isCommit(sha))
        #expect(!HuggingFaceImportLocation.isCommit("main"))
    }

    @Test func fileLinks() throws {
        for action in ["blob", "resolve"] {
            let file = try HuggingFaceImportLocation("https://huggingface.co/owner/model/\(action)/main/model-q4.gguf?download=true")
            #expect(file.selection == .file && file.path == "model-q4.gguf")
        }
    }

    @Test(arguments: [
        "http://huggingface.co/owner/model", "https://huggingface.co.evil.example/owner/model",
        "https://token@huggingface.co/owner/model", "https://huggingface.co/owner/model?token=secret",
        "https://huggingface.co/owner/model#secret", "https://huggingface.co/datasets/owner/model",
        "https://huggingface.co/spaces/owner/model", "https://huggingface.co/owner//model",
        "https://huggingface.co/owner/model/tree/main/../other", "https://huggingface.co/owner/model/tree/main/%2e%2e/other",
        "https://huggingface.co/owner/model/tree/main/%252e%252e/other", "https://huggingface.co/owner/model/resolve/main",
        "https://huggingface.co/owner/model/tree/main/a%2fb", "https://huggingface.co/owner/model/tree/main/a%5cb"
    ])
    func rejectsUnsupportedSources(_ source: String) {
        #expect(throws: HuggingFaceImportLocation.InvalidSource.self) { _ = try HuggingFaceImportLocation(source) }
    }
}
