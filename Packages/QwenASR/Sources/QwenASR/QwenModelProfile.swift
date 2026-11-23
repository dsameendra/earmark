import AppCore
import Foundation

/// Accepted native Qwen architectures. Unknown folders cannot inherit Sinhala or multilingual capabilities.
public struct QwenModelProfile: Sendable {
    public let isSinhala: Bool
    public var languages: Set<LanguageCode> { isSinhala ? [.sinhala] : Set(Self.languageNames.keys) }
    public static let multilingual06: ModelID = "mlx/qwen3-asr-0.6b-4bit"
    public static let multilingual17: ModelID = "mlx/qwen3-asr-1.7b-4bit"
    public static func profile(for model: ModelID) -> Self? {
        switch model {
        case QwenSinhalaTargets.model: Self(isSinhala: true)
        case multilingual06, multilingual17: Self(isSinhala: false)
        default: nil
        }
    }
    // Official Qwen3-ASR language names used in the forced-language prompt and returned language header.
    public static let languageNames: [LanguageCode: String] = [
        "zh": "Chinese", "en": "English", "yue": "Cantonese", "ar": "Arabic", "de": "German",
        "fr": "French", "es": "Spanish", "pt": "Portuguese", "id": "Indonesian", "it": "Italian",
        "ko": "Korean", "ru": "Russian", "th": "Thai", "vi": "Vietnamese", "ja": "Japanese",
        "tr": "Turkish", "hi": "Hindi", "ms": "Malay", "nl": "Dutch", "sv": "Swedish",
        "da": "Danish", "fi": "Finnish", "pl": "Polish", "cs": "Czech", "fil": "Filipino",
        "fa": "Persian", "el": "Greek", "hu": "Hungarian", "mk": "Macedonian", "ro": "Romanian"
    ]
}
