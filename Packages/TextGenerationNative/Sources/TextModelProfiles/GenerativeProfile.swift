import Foundation

public enum GenerativeProfile: String, Sendable {
    case hymt18 = "hymt2-1.8b"
    case hymt7 = "hymt2-7b"
    case gemma4 = "translategemma-4b"
    case gemma12 = "translategemma-12b"

    public var isGemma: Bool { self == .gemma4 || self == .gemma12 }
    public var architecture: String { isGemma ? "gemma3" : "hunyuan-dense" }
    public var parameterRange: ClosedRange<UInt64> {
        switch self {
        case .hymt18: 1_000_000_000...2_500_000_000
        case .hymt7: 5_000_000_000...9_000_000_000
        case .gemma4: 3_000_000_000...5_500_000_000
        case .gemma12: 9_000_000_000...14_000_000_000
        }
    }
    public var maximumFileBytes: UInt64 {
        let gib: UInt64 = 1_024 * 1_024 * 1_024
        return switch self {
        case .hymt18: 2 * gib
        case .hymt7: 6 * gib
        case .gemma4: 4 * gib
        case .gemma12: 10 * gib
        }
    }
    public var languages: [String: String] {
        guard isGemma else { return TranslationLanguageNames.hymt }
        return TranslationLanguageNames.gemma.filter { entry in
            TranslationLanguageNames.gemmaBenchmarkedBases.contains(String(entry.key.split(separator: "-")[0]))
        }
    }
    public var filename: String {
        switch self {
        case .hymt18: "Hy-MT2-1.8B-Q4_K_M.gguf"
        case .hymt7: "Hy-MT2-7B-Q4_K_M.gguf"
        case .gemma4: "translategemma-4b-it.Q4_K_M.gguf"
        case .gemma12: "translategemma-12b-it.Q4_K_M.gguf"
        }
    }

    public func supports(source: String, target: String) -> Bool {
        source != target && languages[source] != nil && languages[target] != nil
    }

    /// Exact pinned data-only chat templates. Do not route these through a
    /// heuristic library formatter: the two Hy-MT variants use different tokens.
    public func prompt(text: String, source: String, target: String) throws -> String {
        let content = try content(text: text, source: source, target: target)
        switch self {
        case .hymt18: return "<｜hy_begin▁of▁sentence｜><｜hy_User｜>" + content + "<｜hy_Assistant｜>"
        case .hymt7: return "<|startoftext|>" + content + "<|extra_0|>"
        case .gemma4, .gemma12: return content
        }
    }

    public func content(text: String, source: String, target: String) throws -> String {
        guard supports(source: source, target: target), let sourceName = languages[source], let targetName = languages[target] else {
            throw NativeTextError(message: "This model profile does not support the requested language pair.")
        }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 16_384, !text.utf8.contains(0) else { throw NativeTextError(message: "Use a nonempty translation segment of at most 16 KB without null characters.") }
        // The model's own template delimiters must never be parsed from transcript
        // content. Keep originals and fail visibly instead of changing their text.
        let delimiters = ["<|", "<｜", "<bos>", "<eos>", "<start_of_turn>", "<end_of_turn>", "<start_of_image>"]
        guard !delimiters.contains(where: { text.contains($0) }) else {
            throw NativeTextError(message: "This text contains model control delimiters. Choose another translation engine for this segment.")
        }
        if !isGemma {
            return "Translate the following text into \(targetName). Note that you should only output the translated result without any additional explanation:\n\n\(text)"
        }
        // Exact text branch of the pinned TranslateGemma template. Tokenization
        // adds the model's BOS once; this string deliberately omits a literal BOS.
        return "<start_of_turn>user\nYou are a professional \(sourceName) (\(source)) to \(targetName) (\(target)) translator. Your goal is to accurately convey the meaning and nuances of the original \(sourceName) text while adhering to \(targetName) grammar, vocabulary, and cultural sensitivities.\nProduce only the \(targetName) translation, without any additional explanations or commentary. Please translate the following \(sourceName) text into \(targetName):\n\n\n\(text)<end_of_turn>\n<start_of_turn>model\n"
    }
}

public struct NativeTextError: Error, LocalizedError, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}
