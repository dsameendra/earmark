/// Finite, architecture-bound native worker profiles. A profile is not a catalog
/// acceptance claim: app activation still requires its own quality/lifecycle gates.
public enum NativeSpeechProfile: String, Sendable {
    case multitalkerV1 = "multitalker-v1"
    case nemotron35 = "nemotron-3.5"

    public var architecture: String { "parakeet" }
    public var variant: String {
        switch self {
        case .multitalkerV1: "multitalker-parakeet-streaming-0.6b-v1"
        case .nemotron35: "nemotron-3.5-asr-streaming-0.6b"
        }
    }

    public var languages: [String] {
        switch self {
        case .multitalkerV1: ["en"]
        case .nemotron35:
            ["en-US", "en-GB", "es-US", "es-ES", "fr-FR", "fr-CA", "it-IT",
             "pt-BR", "pt-PT", "nl-NL", "de-DE", "tr-TR", "ru-RU", "ar-AR",
             "hi-IN", "ja-JP", "ko-KR", "vi-VN", "uk-UA", "pl-PL", "sv-SE",
             "cs-CZ", "nb-NO", "da-DK", "bg-BG", "fi-FI", "hr-HR", "sk-SK",
             "zh-CN", "hu-HU", "ro-RO", "et-EE"]
        }
    }

    /// Base-code defaults are explicit. Unsupported regions/scripts never fall
    /// through to a different locale, and tokenizer-only adaptation tags are excluded.
    public func resolveLanguage(_ requested: String) throws -> String {
        if languages.contains(requested) { return requested }
        if self == .nemotron35, !requested.contains("-"),
           let locale = languages.first(where: { $0.split(separator: "-").first.map(String.init) == requested }) {
            return locale
        }
        throw SpeechWireError.invalid("Unsupported source language.")
    }

    public func matches(architecture: String, variant: String) -> Bool {
        architecture == self.architecture && variant == self.variant
    }

    /// The pinned Parakeet backend strips predicted locale tokens from display
    /// text without populating its language accessor. Recover only a unique,
    /// supported model-emitted tag from its unfiltered decoded output.
    public func detectedLanguage(in rawText: String) -> String? {
        guard self == .nemotron35 else { return nil }
        var detected: String?
        for piece in rawText.split(separator: "<", omittingEmptySubsequences: false).dropFirst() {
            guard let end = piece.firstIndex(of: ">") else { continue }
            let locale = String(piece[..<end])
            guard locale.contains("-") else { continue } // e.g. <unk> is not a locale.
            guard languages.contains(locale) else { return nil }
            if let detected, detected != locale { return nil }
            detected = locale
        }
        return detected
    }
}
