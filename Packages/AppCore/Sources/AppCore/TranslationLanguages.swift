import Foundation

extension LanguageCode {
    /// Identity for same-language translation checks. Region-only variations
    /// retain legacy behavior; explicit writing systems remain distinct.
    public var translationIdentity: LanguageCode {
        let parts = rawValue.replacingOccurrences(of: "_", with: "-").split(separator: "-")
        guard let first = parts.first else { return self }
        let language = first.lowercased()
        let explicitScript = parts.dropFirst().first { part in
            part.count == 4 && part.unicodeScalars.allSatisfy { (65...90).contains($0.value) || (97...122).contains($0.value) }
        }.map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
        if language == "zh" {
            let traditional = parts.dropFirst().contains { ["TW", "HK", "MO"].contains($0.uppercased()) }
            return LanguageCode("zh-" + (explicitScript ?? (traditional ? "Hant" : "Hans")))
        }
        return LanguageCode(language + (explicitScript.map { "-" + $0 } ?? ""))
    }
}

extension LanguagePair {
    public var isSameWrittenLanguage: Bool { source.translationIdentity == target.translationIdentity }
}
