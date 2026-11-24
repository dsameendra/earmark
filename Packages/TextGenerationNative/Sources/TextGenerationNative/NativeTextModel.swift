import EarmarkLlama
import Foundation
import TextModelProfiles

public typealias GenerativeProfile = TextModelProfiles.GenerativeProfile
public typealias NativeTextError = TextModelProfiles.NativeTextError

/// Confined to the isolated helper's serial loop. No runtime downloads or Python.
public final class NativeTextModel {
    private let handle: UnsafeMutableRawPointer
    public let profile: GenerativeProfile

    public init(folder: URL, profile: GenerativeProfile, threads: Int = 4) throws {
        self.profile = profile
        guard folder.isFileURL, (1...64).contains(threads) else { throw NativeTextError(message: "Invalid local model configuration.") }
        var error: UnsafeMutablePointer<CChar>?
        let path = folder.appendingPathComponent(profile.filename).path
        let loaded = path.withCString { path in profile.architecture.withCString { earmark_llama_load(path, $0, profile.parameterRange.lowerBound, profile.parameterRange.upperBound, Int32(threads), &error) } }
        defer { earmark_llama_free_text(error) }
        guard let loaded else { throw NativeTextError(message: error.map { String(cString: $0) } ?? "Could not load the native text model.") }
        handle = loaded
    }

    deinit { earmark_llama_unload(handle) }

    public func prompt(text: String, source: String, target: String) throws -> String {
        let content = try profile.content(text: text, source: source, target: target)
        if profile.isGemma { return content }
        var error: UnsafeMutablePointer<CChar>?
        let result = content.withCString { earmark_llama_chat_prompt(handle, $0, &error) }
        defer { earmark_llama_free_text(result); earmark_llama_free_text(error) }
        guard let result, let value = String(validatingCString: result) else { throw NativeTextError(message: error.map { String(cString: $0) } ?? "Could not apply the model chat template.") }
        return value
    }

    public func translate(text: String, source: String, target: String) throws -> String {
        let input = try prompt(text: text, source: source, target: target)
        var error: UnsafeMutablePointer<CChar>?
        let result = input.withCString { earmark_llama_generate(handle, $0, profile.isGemma ? 2048 : 3072, 1024, &error) }
        defer { earmark_llama_free_text(result); earmark_llama_free_text(error) }
        guard let result, let output = String(validatingCString: result), !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NativeTextError(message: error.map { String(cString: $0) } ?? "The native translator returned no valid text.")
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func tokens(text: String, source: String, target: String) throws -> [Int] {
        let input = try prompt(text: text, source: source, target: target)
        var error: UnsafeMutablePointer<CChar>?
        let result = input.withCString { earmark_llama_tokens(handle, $0, &error) }
        defer { earmark_llama_free_text(result); earmark_llama_free_text(error) }
        guard let result, let value = String(validatingCString: result) else {
            throw NativeTextError(message: error.map { String(cString: $0) } ?? "Native tokenization failed.")
        }
        return try JSONDecoder().decode([Int].self, from: Data(value.utf8))
    }
}
