/// Finite, architecture-bound native worker profiles. A profile is not a catalog
/// acceptance claim: app activation still requires its own quality/lifecycle gates.
public enum NativeSpeechProfile: String, Sendable {
    case multitalkerV1 = "multitalker-v1"
    case nemotron35 = "nemotron-3.5"
    case cohere202603 = "cohere-2026-03"
    case canaryV2 = "canary-v2"

    public var architecture: String {
        switch self {
        case .multitalkerV1, .nemotron35: "parakeet"
        case .cohere202603: "cohere_asr"
        case .canaryV2: "canary"
        }
    }
    public var variant: String {
        switch self {
        case .multitalkerV1: "multitalker-parakeet-streaming-0.6b-v1"
        case .nemotron35: "nemotron-3.5-asr-streaming-0.6b"
        case .cohere202603: "cohere-transcribe-03-2026"
        case .canaryV2: "canary-1b-v2"
        }
    }

    public var languages: [String] {
        switch self {
        case .multitalkerV1: ["en"]
        case .cohere202603: ["en", "fr", "de", "es", "it", "pt", "nl", "pl", "el", "ar", "ja", "zh", "vi", "ko"]
        case .canaryV2:
            ["bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
             "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk"]
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

    public var translationTargets: [String] {
        // The pinned conversion excludes Latvian AST. This restriction needs
        // separate upstream/reference investigation; do not infer it from ASR.
        self == .canaryV2 ? languages.filter { $0 != "lv" } : []
    }

    public func supportsTranslation(source: String, target: String) -> Bool {
        self == .canaryV2 && translationTargets.contains(source) && translationTargets.contains(target)
            && ((source == "en") != (target == "en"))
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
