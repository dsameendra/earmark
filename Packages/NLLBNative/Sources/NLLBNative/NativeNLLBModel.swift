import EarmarkNLLBCore
import Foundation

public enum NativeTranslationProfile: String, Sendable {
    case nllb, madlad, marian
    var bridgeCode: Int32 { switch self { case .nllb: 1; case .madlad: 2; case .marian: 3 } }
}

/// CTranslate2 and SentencePiece behind the stable C bridge. Confined to the native worker's serial request loop.
public final class NativeNLLBModel {
    private let handle: UnsafeMutableRawPointer

    public init(folder: URL, threads: Int = 4, profile: NativeTranslationProfile = .nllb) throws {
        var error: UnsafeMutablePointer<CChar>?
        let loaded = folder.path.withCString { earmark_translation_load($0, profile.bridgeCode, Int32(threads), &error) }
        defer { earmark_nllb_free_text(error) }
        guard let loaded else {
            throw NativeNLLBError(message: error.map { String(cString: $0) } ?? "Could not load the translation model.")
        }
        handle = loaded
    }

    deinit { earmark_nllb_unload(handle) }

    public func translate(_ text: String, source: String, target: String) throws -> String {
        guard ![text, source, target].contains(where: { $0.utf8.contains(0) }) else {
            throw NativeNLLBError(message: "Translation text and language tags cannot contain null characters.")
        }
        var error: UnsafeMutablePointer<CChar>?
        let result = text.withCString { text in
            source.withCString { source in target.withCString { earmark_nllb_translate(handle, text, source, $0, &error) } }
        }
        defer {
            earmark_nllb_free_text(error)
            earmark_nllb_free_text(result)
        }
        guard let result else { throw NativeNLLBError(message: error.map { String(cString: $0) } ?? "Translation failed.") }
        return String(cString: result)
    }

    /// Exact SentencePiece output for parity tests, including its Unicode normalization.
    public func tokens(for text: String) throws -> [String] {
        guard !text.utf8.contains(0) else { throw NativeNLLBError(message: "Tokenization text cannot contain null characters.") }
        var error: UnsafeMutablePointer<CChar>?
        let result = text.withCString { earmark_nllb_encode(handle, $0, &error) }
        defer {
            earmark_nllb_free_text(error)
            earmark_nllb_free_tokens(result)
        }
        guard let result else { throw NativeNLLBError(message: error.map { String(cString: $0) } ?? "Tokenization failed.") }
        return (0..<earmark_nllb_token_count(result)).compactMap { index in earmark_nllb_token(result, index).map { String(cString: $0) } }
    }
}

public struct NativeNLLBError: Error, LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
    public init(message: String) { self.message = message }
}
