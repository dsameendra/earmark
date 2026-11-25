import EarmarkNLLBCore
import Foundation
import ModelLanguageProfiles

public enum NativeTranslationProfile: String, Sendable {
    case nllb, madlad, marian
    var bridgeCode: Int32 { switch self { case .nllb: 1; case .madlad: 2; case .marian: 3 } }
}

/// CTranslate2 and SentencePiece behind the stable C bridge. Confined to the native worker's serial request loop.
public final class NativeNLLBModel {
    private let handle: UnsafeMutableRawPointer
    /// NLLB prefix tokens verified against its actual shared vocabulary; nil for the other tokenizer protocols.
    public let languageTags: Set<String>?

    public init(folder: URL, threads: Int = 4, profile: NativeTranslationProfile = .nllb) throws {
        guard folder.isFileURL, !folder.path.utf8.contains(0), (1...64).contains(threads) else {
            throw NativeNLLBError(message: "Choose a local model folder and between 1 and 64 inference threads.")
        }
        languageTags = profile == .nllb ? try Self.verifiedNLLBTags(folder: folder) : nil
        var error: UnsafeMutablePointer<CChar>?
        let loaded = folder.path.withCString { earmark_translation_load($0, profile.bridgeCode, Int32(threads), &error) }
        defer { earmark_nllb_free_text(error) }
        guard let loaded else {
            throw NativeNLLBError(message: error.map { String(cString: $0) } ?? "Could not load the translation model.")
        }
        handle = loaded
    }

    private static func verifiedNLLBTags(folder: URL) throws -> Set<String> {
        let file = folder.appendingPathComponent("shared_vocabulary.txt")
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let bytes = values.fileSize, bytes > 0, bytes <= 16 * 1_024 * 1_024 else {
            throw NativeNLLBError(message: "The NLLB shared vocabulary is missing, unsafe or oversized.")
        }
        for name in ["shared_vocabulary.json", "source_vocabulary.json", "target_vocabulary.json", "source_vocabulary.txt", "target_vocabulary.txt"] {
            guard !FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) else {
                throw NativeNLLBError(message: "The NLLB folder has conflicting vocabulary files. Use a validated NLLB checkpoint.")
            }
        }
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        let data = try input.read(upToCount: 16 * 1_024 * 1_024 + 1) ?? Data()
        guard data.count <= 16 * 1_024 * 1_024, let text = String(data: data, encoding: .utf8), !text.utf8.contains(0) else {
            throw NativeNLLBError(message: "The NLLB vocabulary is not valid UTF-8 text.")
        }
        let tokens = Set(text.split(separator: "\n").map(String.init))
        let expected = Set(NLLBLanguageProfile.codes.values)
        guard expected.isSubset(of: tokens) else {
            throw NativeNLLBError(message: "This checkpoint does not contain the complete reviewed NLLB language-token inventory.")
        }
        return expected
    }

    deinit { earmark_nllb_unload(handle) }

    public func translate(_ text: String, source: String, target: String) throws -> String {
        guard text.utf8.count <= 100_000, source.utf8.count <= 128, target.utf8.count <= 128, ![text, source, target].contains(where: { $0.utf8.contains(0) }) else {
            throw NativeNLLBError(message: "Translation text or language tags exceed the input limits or contain null characters.")
        }
        if let languageTags, !languageTags.contains(source) || !languageTags.contains(target) {
            throw NativeNLLBError(message: "Unsupported NLLB source or target language token.")
        }
        var error: UnsafeMutablePointer<CChar>?
        let result = text.withCString { text in
            source.withCString { source in target.withCString { earmark_nllb_translate(handle, text, source, $0, &error) } }
        }
        defer {
            earmark_nllb_free_text(error)
            earmark_nllb_free_text(result)
        }
        guard let result, let output = String(validatingCString: result) else { throw NativeNLLBError(message: error.map { String(cString: $0) } ?? "Translation returned invalid text.") }
        return output
    }

    /// Exact SentencePiece output for parity tests, including its Unicode normalization.
    public func tokens(for text: String) throws -> [String] {
        guard text.utf8.count <= 100_000, !text.utf8.contains(0) else { throw NativeNLLBError(message: "Tokenization input exceeds the limit or contains null characters.") }
        var error: UnsafeMutablePointer<CChar>?
        let result = text.withCString { earmark_nllb_encode(handle, $0, &error) }
        defer {
            earmark_nllb_free_text(error)
            earmark_nllb_free_tokens(result)
        }
        guard let result else { throw NativeNLLBError(message: error.map { String(cString: $0) } ?? "Tokenization failed.") }
        let count = earmark_nllb_token_count(result)
        guard count <= 200_000 else { throw NativeNLLBError(message: "Native tokenization exceeded the output limit.") }
        return try (0..<count).map { index in
            guard let token = earmark_nllb_token(result, index), let value = String(validatingCString: token) else {
                throw NativeNLLBError(message: "Native tokenization returned an invalid token.")
            }
            return value
        }
    }
}

public struct NativeNLLBError: Error, LocalizedError, Equatable, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(message: String) { self.message = message }
}
